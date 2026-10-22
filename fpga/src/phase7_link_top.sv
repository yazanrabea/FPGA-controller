`timescale 1ns / 1ps
//==========================================================================
// phase7_link_top
//
// generic_controller_prompt.md §3 Phase 7 round 2: the Phase 7 step
// sequencer with its step table written from the PC over the UART link
// (register map v2, docs/link_register_map.md), so a sequence, and the
// program-verify loop (tools/nemo_ctl/sequence.program_verify), run without
// re-synthesis. Same 5 loopback cells and strobe wiring as
// phase7_seq_loopback_top.sv (target PHASE7_LOOPBACK); field offsets in a
// step entry come from fpga/src/gen/phase7_link_pkg.sv (gen_svh.py
// --phase7-link, the one layout shared with the Python encoder).
//
//   PC --UART--> link_frame --bus--> v2 registers / step-table RAM (seq_bank)
//   seq_bank's next-step bank --> cells' cfg, header --> seq_engine
//   Commands: RUN = start the sequence, STOP = abort it, APPLY = re-apply
//   step 0 with RUN low (idle state, e.g. right after loading a table).
//   Table and N_STEPS writes are refused while a sequence runs
//   (STATUS.TABLE_REJECTED).
//
// rxd/txd are NOT constrained in the XDC: the USB-UART adapter's PMOD pin
// and bank voltage are still unconfirmed (EXP-02, docs/controller_spec.md
// §9), same as phase5_link_top. Do not invent a pin.
//
// LEDs: LD0-LD2 step (current while running, last afterwards), LD3 busy,
// LD4 done, LD5 FAULT, LD6 LATE, LD7 link error (UART framing error or
// input-FIFO overflow, sticky).
//==========================================================================
module phase7_link_top #(
    parameter int    BAUD = 115_200,  // the testbench runs it faster
    // Byte transport (docs/decisions.md, 2026-10-22: JTAG over J17 chosen):
    //   "UART": uart_rx/uart_tx on rxd/txd (pins TBD, see header).
    //   "JTAG": jtag_link_bscan (BSCANE2 USER4 over the J17 PROG cable); rxd/txd unused.
    //           Built through phase7_link_jtag_top.sv, which has no rxd/txd ports.
    parameter string LINK = "UART"
) (
    input  logic        clk,         // 100 MHz ZedBoard system clock
    output logic [7:0]  led,
    inout  wire  [31:0] fmc_pins,
    input  logic        rxd,         // pin TBD, see header
    output logic        txd          // pin TBD, see header
);

    localparam int TW  = 32;
    localparam int NS  = phase7_link_pkg::N_SIG;
    localparam int NC  = phase7_link_pkg::N_CAP;
    localparam int SW  = phase7_link_pkg::STEP_W;
    localparam int EB  = phase7_link_pkg::ENTRY_BYTES;
    localparam int UB  = phase7_link_pkg::USED_BYTES;
    localparam int HB  = phase7_link_pkg::HDR_BYTES;
    localparam int CS  = phase7_link_pkg::CAP_STRIDE;
    localparam int CD  = phase7_link_pkg::CAP_DATA;
    localparam int CB  = phase7_link_pkg::CAP_BYTES;
    localparam int TAW = SW + $clog2(EB);              // table byte-address width
    localparam logic [15:0] TBASE = phase7_link_pkg::TABLE_BASE;
    localparam logic [15:0] CBASE = phase7_link_pkg::CAP_BASE;

    // ---- power-on reset (no reset button wired on this board) ----
    logic [3:0] por_cnt = 4'd0;
    logic       rst_n;
    always_ff @(posedge clk) if (por_cnt != 4'hF) por_cnt <= por_cnt + 4'd1;
    assign rst_n = (por_cnt == 4'hF);

    // ---- UART + frame engine ----
    logic [7:0] rx_byte, tx_byte;
    logic rx_byte_valid, rx_frame_error, tx_send, tx_busy;  // rx_frame_error: JTAG = down FIFO overrun
    generate
        if (LINK == "JTAG") begin : g_jtag
            jtag_link_bscan u_jtag (.clk(clk), .rst_n(rst_n),
                .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
                .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
                .dn_overflow(rx_frame_error));
            assign txd = 1'b1;               // unused (no pin in the JTAG top)
        end else begin : g_uart
            uart_rx #(.BAUD(BAUD)) u_uart_rx (.clk(clk), .rst_n(rst_n), .rx(rxd),
                .data_out(rx_byte), .valid(rx_byte_valid), .frame_error(rx_frame_error));
            uart_tx #(.BAUD(BAUD)) u_uart_tx (.clk(clk), .rst_n(rst_n),
                .data_in(tx_byte), .send(tx_send), .busy(tx_busy), .tx(txd));
        end
    endgenerate

    logic        bus_we, bus_re, cmd_apply, cmd_run, cmd_stop, rx_overflow;
    logic [15:0] bus_waddr, bus_raddr;
    logic [7:0]  bus_wdata, bus_rdata;
    link_frame #(.MAX_PAYLOAD(255), .CAP_BASE(CBASE), .STATUS_ADDR(phase7_link_pkg::REG_STATUS)) u_frame (
        .clk(clk), .rst_n(rst_n),
        .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
        .bus_we(bus_we), .bus_waddr(bus_waddr), .bus_wdata(bus_wdata),
        .bus_re(bus_re), .bus_raddr(bus_raddr), .bus_rdata(bus_rdata),
        .cmd_apply(cmd_apply), .cmd_run(cmd_run), .cmd_stop(cmd_stop),
        .rx_overflow(rx_overflow));

    // ---- engine + bank ----
    logic [SW-1:0] step, last_step, fetch_step;
    logic run, busy, seq_done, fault, aborted, late, step_start, apply_tick, fetch_ready;
    logic [NS-1:0] sig_apply;
    logic [NC-1:0] cap_apply;
    // driven element by element from separate cell ports: wire (one driver per element)
    wire  [NS-1:0] sig_done;
    wire  [NC-1:0] cap_done, cap_level;
    wire  [NC*TW-1:0] cap_edges;
    logic [UB*8-1:0] nx;      // next-step bank: every cell's cfg comes from here
    logic [HB*8-1:0] hdr;     // header of the current step
    logic [SW:0] n_steps;

    logic in_table, tbl_we;
    assign in_table = (bus_waddr >= TBASE) && (bus_waddr < TBASE + (2 ** SW) * EB);
    assign tbl_we   = bus_we && in_table && !busy;

    seq_bank #(.STEP_W(SW), .ENTRY_BYTES(EB), .USED_BYTES(UB), .HDR_BYTES(HB)) u_bank (
        .clk(clk), .rst_n(rst_n),
        .wr_en(tbl_we), .wr_addr(TAW'(bus_waddr - TBASE)), .wr_data(bus_wdata),
        .fetch_step(fetch_step), .fetch_ready(fetch_ready), .apply_tick(apply_tick),
        .next_entry(nx), .hdr(hdr));

    seq_engine #(.N_SIG(NS), .N_CAP(NC), .TICK_W(TW), .STEP_W(SW)) u_engine (
        .clk(clk), .rst_n(rst_n), .start(cmd_run), .abort(cmd_stop), .preload(cmd_apply),
        .n_steps(n_steps),
        .step_sig_mask(hdr[phase7_link_pkg::H_SIG_MASK*8 +: NS]),
        .step_cap_mask(hdr[phase7_link_pkg::H_CAP_MASK*8 +: NC]),
        .step_cond(hdr[phase7_link_pkg::H_COND*8 +: 3]),
        .step_cond_cell(hdr[phase7_link_pkg::H_COND_CELL*8 +: 8]),
        .step_cond_arg(hdr[phase7_link_pkg::H_COND_ARG*8 +: TW]),
        .step_timeout(hdr[phase7_link_pkg::H_TIMEOUT*8 +: TW]),
        .fetch_step(fetch_step), .fetch_ready(fetch_ready),
        .sig_done(sig_done), .cap_done(cap_done), .cap_level(cap_level), .cap_edges(cap_edges),
        .step(step), .run(run), .sig_apply(sig_apply), .cap_apply(cap_apply), .apply_tick(apply_tick),
        .busy(busy), .seq_done(seq_done), .fault(fault), .aborted(aborted), .late(late),
        .last_step(last_step), .step_start(step_start));

    // ---- v2 registers ----
    logic [7:0] scratch;
    logic       table_rejected;   // a table / N_STEPS write arrived while busy (sticky)
    logic       link_error;       // UART framing error or input-FIFO overflow (sticky)
    logic [7:0] status;
    assign status = {rx_overflow, table_rejected, late, aborted, fault, seq_done, busy, run};

    wire  [NC-1:0][15:0] cap_reg;  // each cap cell's capture register, zero-extended

    function automatic logic [7:0] read_byte(input logic [15:0] a);
        int k, off;
        logic [31:0] e;
        logic [15:0] c;
        if (a == 16'h0000)                    return scratch;
        if (a == phase7_link_pkg::REG_STATUS)    return status;
        if (a == phase7_link_pkg::REG_STEP)      return 8'(step);
        if (a == phase7_link_pkg::REG_LAST_STEP) return 8'(last_step);
        if (a == phase7_link_pkg::REG_N_STEPS)   return 8'(n_steps);
        if (a >= CBASE && a < CBASE + NC * CS) begin
            k   = (a - CBASE) / CS;
            off = (a - CBASE) % CS;
            c   = cap_reg[k];
            if (off == 0) return {5'b0, cap_done[k], 1'b0, cap_level[k]};
            if (off >= 1 && off <= 4) begin e = cap_edges[k*TW +: TW]; return e[(off-1)*8 +: 8]; end
            if (off >= CD && off < CD + CB) return c[(off-CD)*8 +: 8];
            return 8'h00;
        end
        return 8'h00;  // table (write-only) and everything unused
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch        <= '0;
            n_steps        <= 1;
            table_rejected <= 1'b0;
            link_error     <= 1'b0;
            bus_rdata      <= '0;
        end else begin
            if (rx_frame_error || rx_overflow) link_error <= 1'b1;
            if (bus_re) bus_rdata <= read_byte(bus_raddr);
            if (bus_we) begin
                if (bus_waddr == 16'h0000) scratch <= bus_wdata;
                if (bus_waddr == phase7_link_pkg::REG_STATUS) table_rejected <= 1'b0;
                if (bus_waddr == phase7_link_pkg::REG_N_STEPS) begin
                    if (busy) table_rejected <= 1'b1;
                    else n_steps <= (bus_wdata == 0) ? 1 : (bus_wdata > 2 ** SW) ? (2 ** SW) : bus_wdata[SW:0];
                end
                if (in_table && busy) table_rejected <= 1'b1;
            end
        end
    end

    // ---- 5 sig cells, cfg = the next-step bank (they only latch it on an APPLY) ----
    wire  [NS-1:0] pin_out;
    wire  clk_rise, clk_fall;
    wire  [NS-1:0] rise_nc, fall_nc;   // edge strobes nobody uses

    `define P7_SIG(INST, B, SWID, IDX, STROBE, RISE, FALL) \
        sig_cell #(.TICK_W(TW), .SERIAL_W(SWID)) INST ( \
            .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[IDX]), \
            .cfg_type(nx[(B + phase7_link_pkg::F_SIG_CTRL)*8 +: 3]), \
            .cfg_idle_level(nx[(B + phase7_link_pkg::F_SIG_CTRL)*8 + 3]), \
            .cfg_msb_first(nx[(B + phase7_link_pkg::F_SIG_CTRL)*8 + 4]), \
            .cfg_delay(nx[(B + phase7_link_pkg::F_SIG_DELAY)*8 +: TW]), \
            .cfg_param_a(nx[(B + phase7_link_pkg::F_SIG_PARAM_A)*8 +: TW]), \
            .cfg_param_b(nx[(B + phase7_link_pkg::F_SIG_PARAM_B)*8 +: TW]), \
            .cfg_cycles(nx[(B + phase7_link_pkg::F_SIG_CYCLES)*8 +: TW]), \
            .cfg_bits(nx[(B + phase7_link_pkg::F_SIG_BITS)*8 +: TW]), \
            .cfg_data(nx[(B + phase7_link_pkg::F_SIG_DATA)*8 +: SWID]), \
            .shift_strobe(STROBE), \
            .pin_out(pin_out[IDX]), .rising_edge(RISE), .falling_edge(FALL), .active(), .done(sig_done[IDX]));

    `P7_SIG(u_clk,  phase7_link_pkg::CLK_BASE,  1,  0, 1'b0,     clk_rise, clk_fall)
    `P7_SIG(u_rst,  phase7_link_pkg::RST_BASE,  1,  1, 1'b0,     rise_nc[1], fall_nc[1])
    `P7_SIG(u_data, phase7_link_pkg::DATA_BASE, 16, 2, clk_fall, rise_nc[2], fall_nc[2])
    `P7_SIG(u_cs,   phase7_link_pkg::CS_BASE,   1,  3, 1'b0,     rise_nc[3], fall_nc[3])
    `P7_SIG(u_en,   phase7_link_pkg::EN_BASE,   1,  4, 1'b0,     rise_nc[4], fall_nc[4])
    `undef P7_SIG

    // ---- FMC pins: 0-4 straight from the cells' output FFs, the rest tri-stated ----
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : g_pins
            if (g < NS) assign fmc_pins[g] = pin_out[g];
            else        assign fmc_pins[g] = 1'bz;
        end
    endgenerate

    // ---- 2-FF sync on the 5 loopback inputs (CLAUDE.md §8) ----
    logic [NC-1:0] in_s0, in_s1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin in_s0 <= '0; in_s1 <= '0; end
        else begin in_s0 <= fmc_pins[16 +: NC]; in_s1 <= in_s0; end
    end

    // ---- 5 cap cells ----
    `define P7_CAP(INST, B, CWID, IDX, STROBE, REG) \
        cap_cell #(.TICK_W(TW), .CAP_W(CWID)) INST ( \
            .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[IDX]), .sync_in(in_s1[IDX]), \
            .cfg_mode(nx[(B + phase7_link_pkg::F_CAP_CTRL)*8 +: 2]), \
            .cfg_msb_first(nx[(B + phase7_link_pkg::F_CAP_CTRL)*8 + 2]), \
            .cfg_bits(nx[(B + phase7_link_pkg::F_CAP_BITS)*8 +: TW]), .capture_strobe(STROBE), \
            .level_out(cap_level[IDX]), .edge_count(cap_edges[IDX*TW +: TW]), .period_ticks(), \
            .high_ticks(), .period_valid(), .capture_reg(REG), .done(cap_done[IDX]));

    wire  [NC-1:0] cap_bit;
    wire  [15:0]   data_in_reg;
    `P7_CAP(u_clk_in,  phase7_link_pkg::CLK_IN_BASE,  1,  0, 1'b0,     cap_bit[0])
    `P7_CAP(u_rst_in,  phase7_link_pkg::RST_IN_BASE,  1,  1, 1'b0,     cap_bit[1])
    `P7_CAP(u_data_in, phase7_link_pkg::DATA_IN_BASE, 16, 2, clk_rise, data_in_reg)
    `P7_CAP(u_cs_in,   phase7_link_pkg::CS_IN_BASE,   1,  3, 1'b0,     cap_bit[3])
    `P7_CAP(u_en_in,   phase7_link_pkg::EN_IN_BASE,   1,  4, 1'b0,     cap_bit[4])
    `undef P7_CAP
    assign cap_bit[2] = 1'b0;
    assign cap_reg[0] = {15'b0, cap_bit[0]};
    assign cap_reg[1] = {15'b0, cap_bit[1]};
    assign cap_reg[2] = data_in_reg;
    assign cap_reg[3] = {15'b0, cap_bit[3]};
    assign cap_reg[4] = {15'b0, cap_bit[4]};

    logic [SW-1:0] shown;
    assign shown    = busy ? step : last_step;
    assign led[2:0] = shown[2:0];
    assign led[3]   = busy;
    assign led[4]   = seq_done;
    assign led[5]   = fault;
    assign led[6]   = late;
    assign led[7]   = link_error;

endmodule
