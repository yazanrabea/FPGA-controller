`timescale 1ns / 1ps
//==========================================================================
// phase5_link_top
//
// generic_controller_prompt.md §3 Phase 5: runtime link. Same 5 test pairs
// as phase4_loopback_top.sv (test_clock/test_pulse/test_serial/test_low/
// test_high on loopback pairs 0-4) -- still NOT the real chip config, no
// FMC pin assignment exists for that yet -- but RUN/STOP/APPLY and every
// cfg_* field now come from link_ctrl.sv's register file over a UART link
// instead of compile-time constants. This is what makes Phase 5's own exit
// criterion checkable at all: "change a clock frequency from the PC
// without re-synthesis and see it on the multimeter/scope."
//
// docs/link_register_map.md has the full byte-level register map. Python
// side: tools/nemo_ctl/link.py.
//
// **Open item carried from Phase 0, still unresolved**: the PMOD bank
// voltage for the USB-UART adapter (link option (a), chosen in Phase 0) is
// not in any repo file and has never been checked against the ZedBoard
// reference manual. `rxd`/`txd` below are therefore NOT constrained in
// phase5_link_top.xdc -- building this in Vivado will warn about
// unconstrained I/O until that's confirmed and the XDC updated. Do not
// invent a PMOD pin assignment; see docs/USER_MANUAL.md's Phase 5 section.
//
// RUN is exclusively link-controlled here (CMD_RUN/CMD_STOP), unlike
// Phase 4's sw[4] switch -- that's the point of this phase. sw[2:0] still
// just selects which pair's status shows on the LEDs, same as Phase 4.
//==========================================================================
module phase5_link_top (
    input  logic        clk,        // 100 MHz ZedBoard system clock
    input  logic [2:0]  sw,
    output logic [7:0]  led,
    inout  wire  [31:0] fmc_pins,

    input  logic        rxd,        // from the PC's USB-UART adapter TX -- pin TBD, see header
    output logic        txd         // to the PC's USB-UART adapter RX -- pin TBD, see header
);

    localparam int N_SIG = 5;
    localparam int N_CAP = 5;

    // internal helper clock's timing (shift/capture strobe for test_serial) is a fixed
    // compile-time constant here, same 10 Hz as Phase 4 -- it's internal plumbing, not
    // exposed as a 6th link-controlled cell this phase. TICK_W=32 matches sig_cell's
    // own default and link_ctrl's 32-bit register fields.
    localparam int TICK_W = 32;
    localparam logic [TICK_W-1:0] SERIAL_STROBE_PERIOD = 10_000_000;  // 10 Hz
    localparam logic [TICK_W-1:0] SERIAL_STROBE_HIGH   = 5_000_000;

    // ---- power-on reset (no reset button wired on this board) ----
    logic [3:0] por_cnt = 4'd0;
    logic       rst_n;
    always_ff @(posedge clk) begin
        if (por_cnt != 4'hF) por_cnt <= por_cnt + 4'd1;
    end
    assign rst_n = (por_cnt == 4'hF);

    // ---- UART + link ----
    logic [7:0] rx_byte;
    logic        rx_byte_valid;
    logic        rx_frame_error;
    logic [7:0] tx_byte;
    logic        tx_send;
    logic        tx_busy;

    uart_rx u_uart_rx (
        .clk(clk), .rst_n(rst_n), .rx(rxd),
        .data_out(rx_byte), .valid(rx_byte_valid), .frame_error(rx_frame_error)
    );
    uart_tx u_uart_tx (
        .clk(clk), .rst_n(rst_n),
        .data_in(tx_byte), .send(tx_send), .busy(tx_busy), .tx(txd)
    );

    logic run, apply;
    logic run_set, run_clear, apply_cmd;

    logic [2:0]  sig_cfg_type[N_SIG];
    logic         sig_cfg_idle_level[N_SIG];
    logic         sig_cfg_msb_first[N_SIG];
    logic [31:0] sig_cfg_delay[N_SIG];
    logic [31:0] sig_cfg_param_a[N_SIG];
    logic [31:0] sig_cfg_param_b[N_SIG];
    logic [31:0] sig_cfg_cycles[N_SIG];
    logic [15:0] sig_cfg_data[N_SIG];
    logic [31:0] sig_cfg_bits[N_SIG];

    logic [1:0]  cap_cfg_mode[N_CAP];
    logic         cap_cfg_msb_first[N_CAP];
    logic [31:0] cap_cfg_bits[N_CAP];

    logic         cap_level_out[N_CAP];
    logic         cap_period_valid[N_CAP];
    logic         cap_done[N_CAP];
    logic [31:0] cap_edge_count[N_CAP];
    logic [31:0] cap_period_ticks[N_CAP];
    logic [31:0] cap_high_ticks[N_CAP];
    logic [15:0] cap_capture_reg[N_CAP];

    link_ctrl #(.N_SIG(N_SIG), .N_CAP(N_CAP)) u_link_ctrl (
        .clk(clk), .rst_n(rst_n),
        .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd), .run(run),
        .sig_cfg_type(sig_cfg_type), .sig_cfg_idle_level(sig_cfg_idle_level),
        .sig_cfg_msb_first(sig_cfg_msb_first), .sig_cfg_delay(sig_cfg_delay),
        .sig_cfg_param_a(sig_cfg_param_a), .sig_cfg_param_b(sig_cfg_param_b),
        .sig_cfg_cycles(sig_cfg_cycles), .sig_cfg_data(sig_cfg_data), .sig_cfg_bits(sig_cfg_bits),
        .cap_cfg_mode(cap_cfg_mode), .cap_cfg_msb_first(cap_cfg_msb_first), .cap_cfg_bits(cap_cfg_bits),
        .cap_level_out(cap_level_out), .cap_period_valid(cap_period_valid), .cap_done(cap_done),
        .cap_edge_count(cap_edge_count), .cap_period_ticks(cap_period_ticks),
        .cap_high_ticks(cap_high_ticks), .cap_capture_reg(cap_capture_reg)
    );

    run_ctrl u_run_ctrl (
        .clk(clk), .rst_n(rst_n),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd),
        .run(run), .apply(apply)
    );

    // ---- which pair's status to show on the LEDs ----
    logic [2:0] sel;
    assign sel = (sw < 3'd5) ? sw : 3'd0;

    // ---- internal helper clock for test_serial's shift/capture strobe --
    //      NOT tied to any FMC pin, NOT link-controlled (see header comment).
    //      falling_edge, not rising_edge: a freshly-started CLOCK's first
    //      rising_edge fires immediately (idle -> first-high transition),
    //      which would shift the first bit away before it's presented --
    //      same fix as phase4_loopback_top.sv.
    logic serial_strobe, unused_rise, unused_active, unused_done;
    sig_cell #(.TICK_W(TICK_W), .SERIAL_W(1)) u_serial_strobe_gen (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(3'd3 /*CLOCK*/), .cfg_idle_level(1'b0),
        .cfg_delay('0), .cfg_param_a(SERIAL_STROBE_PERIOD), .cfg_param_b(SERIAL_STROBE_HIGH),
        .cfg_cycles('0), .cfg_msb_first(1'b1), .cfg_data('0), .cfg_bits('0),
        .shift_strobe(1'b0),
        .pin_out(), .rising_edge(unused_rise), .falling_edge(serial_strobe),
        .active(unused_active), .done(unused_done)
    );

    // ---- 5 driven test pairs, cfg_* from the link's register file ----
    logic [4:0] pin_out_vec;
    logic [4:0] rising_vec, falling_vec, active_vec, done_vec;

    // Instantiated per-case (not with a width-ternary in the port list) because a
    // conditional expression mixing a 16-bit and a 1-bit branch is fragile even where
    // legal (an input connection) -- and outright invalid where the matching cap_cell
    // loop below needs it on an OUTPUT port, so both are written the same clean way.
    genvar gi;
    generate
        for (gi = 0; gi < N_SIG; gi = gi + 1) begin : g_sig
            if (gi == 2) begin : g_sig_serial
                sig_cell #(.TICK_W(TICK_W), .SERIAL_W(16)) u_sig (
                    .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
                    .cfg_type(sig_cfg_type[gi]), .cfg_idle_level(sig_cfg_idle_level[gi]),
                    .cfg_delay(sig_cfg_delay[gi]), .cfg_param_a(sig_cfg_param_a[gi]),
                    .cfg_param_b(sig_cfg_param_b[gi]), .cfg_cycles(sig_cfg_cycles[gi]),
                    .cfg_msb_first(sig_cfg_msb_first[gi]),
                    .cfg_data(sig_cfg_data[gi]), .cfg_bits(sig_cfg_bits[gi]),
                    .shift_strobe(serial_strobe),
                    .pin_out(pin_out_vec[gi]), .rising_edge(rising_vec[gi]), .falling_edge(falling_vec[gi]),
                    .active(active_vec[gi]), .done(done_vec[gi])
                );
            end else begin : g_sig_plain
                sig_cell #(.TICK_W(TICK_W), .SERIAL_W(1)) u_sig (
                    .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
                    .cfg_type(sig_cfg_type[gi]), .cfg_idle_level(sig_cfg_idle_level[gi]),
                    .cfg_delay(sig_cfg_delay[gi]), .cfg_param_a(sig_cfg_param_a[gi]),
                    .cfg_param_b(sig_cfg_param_b[gi]), .cfg_cycles(sig_cfg_cycles[gi]),
                    .cfg_msb_first(sig_cfg_msb_first[gi]),
                    .cfg_data(sig_cfg_data[gi][0:0]), .cfg_bits(sig_cfg_bits[gi]),
                    .shift_strobe(1'b0),
                    .pin_out(pin_out_vec[gi]), .rising_edge(rising_vec[gi]), .falling_edge(falling_vec[gi]),
                    .active(active_vec[gi]), .done(done_vec[gi])
                );
            end
        end
    endgenerate

    // ---- drive the 5 output FMC pins; tri-state the rest of that range ----
    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_out
            if (g < 5)
                assign fmc_pins[g] = pin_out_vec[g];
            else
                assign fmc_pins[g] = 1'bz;
        end
    endgenerate
    generate
        for (g = 16; g < 32; g = g + 1) begin : g_in_z
            assign fmc_pins[g] = 1'bz;
        end
    endgenerate

    // ---- 2-FF sync on the 5 input FMC pins, external to cap_cell ----
    logic [4:0] sync0, sync_in_vec;
    always_ff @(posedge clk) begin
        sync0       <= {fmc_pins[20], fmc_pins[19], fmc_pins[18], fmc_pins[17], fmc_pins[16]};
        sync_in_vec <= sync0;
    end

    logic [4:0] level_out_vec;
    logic [4:0] cap_done_vec;

    generate
        for (gi = 0; gi < N_CAP; gi = gi + 1) begin : g_cap
            if (gi == 2) begin : g_cap_serial
                cap_cell #(.TICK_W(TICK_W), .CAP_W(16)) u_cap (
                    .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
                    .sync_in(sync_in_vec[gi]),
                    .cfg_mode(cap_cfg_mode[gi]), .cfg_msb_first(cap_cfg_msb_first[gi]),
                    .cfg_bits(cap_cfg_bits[gi]),
                    .capture_strobe(serial_strobe),
                    .level_out(level_out_vec[gi]), .edge_count(cap_edge_count[gi]),
                    .period_ticks(cap_period_ticks[gi]), .high_ticks(cap_high_ticks[gi]),
                    .period_valid(cap_period_valid[gi]),
                    .capture_reg(cap_capture_reg[gi]),
                    .done(cap_done_vec[gi])
                );
            end else begin : g_cap_plain
                logic cap_bit;
                cap_cell #(.TICK_W(TICK_W), .CAP_W(1)) u_cap (
                    .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
                    .sync_in(sync_in_vec[gi]),
                    .cfg_mode(cap_cfg_mode[gi]), .cfg_msb_first(cap_cfg_msb_first[gi]),
                    .cfg_bits(cap_cfg_bits[gi]),
                    .capture_strobe(1'b0),
                    .level_out(level_out_vec[gi]), .edge_count(cap_edge_count[gi]),
                    .period_ticks(cap_period_ticks[gi]), .high_ticks(cap_high_ticks[gi]),
                    .period_valid(cap_period_valid[gi]),
                    .capture_reg(cap_bit),
                    .done(cap_done_vec[gi])
                );
                assign cap_capture_reg[gi] = {15'b0, cap_bit};
            end
            assign cap_level_out[gi] = level_out_vec[gi];
            assign cap_done[gi]      = cap_done_vec[gi];
        end
    endgenerate

    // ---- live match + sticky fault latch (same pattern as phase4_loopback_top.sv) ----
    logic [4:0] match_vec;
    assign match_vec[0] = (pin_out_vec[0] == level_out_vec[0]);
    assign match_vec[1] = (pin_out_vec[1] == level_out_vec[1]);
    assign match_vec[2] = cap_done_vec[2];  // test_serial: "a capture just completed", not a level compare
    assign match_vec[3] = (pin_out_vec[3] == level_out_vec[3]);
    assign match_vec[4] = (pin_out_vec[4] == level_out_vec[4]);

    localparam int SETTLE_CYCLES      = 2_000_000; // ~20 ms at 100 MHz
    localparam int MISMATCH_THRESHOLD = 16;
    logic [21:0] settle_cnt;
    logic        settled;
    logic [4:0]  mismatch_run;
    logic        fault_latch;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || !run) begin
            settle_cnt   <= '0;
            settled      <= 1'b0;
            mismatch_run <= '0;
            fault_latch  <= 1'b0;
        end else if (!settled) begin
            if (settle_cnt == SETTLE_CYCLES[21:0]) settled <= 1'b1;
            else settle_cnt <= settle_cnt + 22'd1;
        end else if (sel == 3'd2) begin
            mismatch_run <= '0;  // test_serial's match_vec isn't a level compare; don't fault on it
        end else if (match_vec[sel]) begin
            mismatch_run <= '0;
        end else if (mismatch_run == MISMATCH_THRESHOLD[4:0] - 5'd1) begin
            fault_latch <= 1'b1;
        end else begin
            mismatch_run <= mismatch_run + 5'd1;
        end
    end

    // sticky UART framing-error indicator (debug aid), cleared only by reset
    logic uart_frame_error_sticky;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) uart_frame_error_sticky <= 1'b0;
        else if (rx_frame_error) uart_frame_error_sticky <= 1'b1;
    end

    assign led[0]   = pin_out_vec[sel];
    assign led[1]   = level_out_vec[sel];
    assign led[2]   = match_vec[sel];
    assign led[3]   = fault_latch;
    assign led[4]   = run;
    assign led[5]   = uart_frame_error_sticky;
    assign led[7:6] = 2'b0;

endmodule
