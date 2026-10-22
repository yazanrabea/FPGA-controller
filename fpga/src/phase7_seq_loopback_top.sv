`timescale 1ns / 1ps
//==========================================================================
// phase7_seq_loopback_top
//
// generic_controller_prompt.md §3 Phase 7 (mode sequencer), hardware
// bring-up: seq_engine running a compile-time step table
// (fpga/src/gen/phase7_cfg_pkg.sv, from config/phase7_seq_loopback.yaml via
// gen_svh.py --phase7) on the same 5 loopback pairs as Phase 4. NOT the chip
// config (no chip-pin -> FMC map yet).
//
// Cells (index = FMC pin; cap cell i reads pin i+16 through the jumper):
//   sig 0 clk   -> LA00_P (J3-0)    cap 0 clk_in  <- LA16_P (J3-16)
//   sig 1 rst   -> LA01_P (J3-1)    cap 1 rst_in  <- LA17_P (J2-17)
//   sig 2 data  -> LA02_P (J3-2)    cap 2 data_in <- LA18_P (J2-18)
//   sig 3 cs    -> LA03_P (J3-3)    cap 3 cs_in   <- LA19_P (J2-19)
//   sig 4 en    -> LA04_P (J3-4)    cap 4 en_in   <- LA20_P (J2-20)
// Hard-wired strobes (must match sequence.PHASE7_LOOPBACK): data shifts on
// clk's falling_edge (SERIAL_W 16); data_in captures on clk's rising_edge
// (CAP_W 16), half a period after data changed.
//
// Switch: sw[4] up = START, sw[4] down = ABORT (if still running). 2-FF
// synchronized, then debounced: a new level counts only after it has been
// stable DEBOUNCE_TICKS (default 2,000,000 = 20 ms, the settle window
// CLAUDE.md §5 found the switch needs). sw[3:0] unused.
//
// LEDs:
//   LD0-LD2 current step while running, the step it ended on when idle
//   LD3 busy, LD4 done (sequence finished), LD5 FAULT (a wait timed out),
//   LD6 data_in == expected pattern (sticky, set when data_in finishes a
//       capture, cleared on START), LD7 aborted.
// After reset the engine preloads step 0, so every pin sits at step 0's
// idle level (not 0) before START.
//==========================================================================
module phase7_seq_loopback_top #(
    parameter int DEBOUNCE_TICKS = 2_000_000
) (
    input  logic        clk,        // 100 MHz ZedBoard system clock
    input  logic [4:0]  sw,
    output logic [7:0]  led,
    inout  wire  [31:0] fmc_pins
);

    // explicit phase7_cfg_pkg:: scoping, not a wildcard import (Icarus, see phase4_loopback_top.sv)
    localparam int TW = phase7_cfg_pkg::TICK_W;
    localparam int NS = phase7_cfg_pkg::N_SIG;
    localparam int NC = phase7_cfg_pkg::N_CAP;
    localparam int SW = phase7_cfg_pkg::STEP_W;

    // ---- power-on reset (no reset button wired on this board) ----
    logic [3:0] por_cnt = 4'd0;
    logic       rst_n;
    always_ff @(posedge clk) begin
        if (por_cnt != 4'hF) por_cnt <= por_cnt + 4'd1;
    end
    assign rst_n = (por_cnt == 4'hF);

    // ---- sw[4]: 2-FF sync + debounce -> start / abort pulses ----
    logic sw_s0, sw_s1, sw_db;
    logic [21:0] db_cnt;
    logic start, abort;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_s0 <= 1'b0; sw_s1 <= 1'b0; sw_db <= 1'b0; db_cnt <= '0;
            start <= 1'b0; abort <= 1'b0;
        end else begin
            sw_s0 <= sw[4];
            sw_s1 <= sw_s0;
            start <= 1'b0;
            abort <= 1'b0;
            if (sw_s1 == sw_db) begin
                db_cnt <= '0;
            end else if (db_cnt == DEBOUNCE_TICKS[21:0] - 1) begin
                db_cnt <= '0;
                sw_db  <= sw_s1;
                start  <= sw_s1;
                abort  <= !sw_s1;
            end else begin
                db_cnt <= db_cnt + 1'b1;
            end
        end
    end

    // ---- engine ----
    logic [SW-1:0] step, last_step;
    logic run, busy, seq_done, fault, aborted, step_start;
    logic [NS-1:0] sig_apply, sig_done;
    logic [NC-1:0] cap_apply, cap_done, cap_level;
    logic [NC*TW-1:0] cap_edges;

    seq_engine #(.N_SIG(NS), .N_CAP(NC), .TICK_W(TW), .STEP_W(SW)) u_engine (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort), .preload(1'b0),
        .n_steps(phase7_cfg_pkg::N_STEPS),
        .step_sig_mask(phase7_cfg_pkg::STEP_SIG_MASK[step*NS +: NS]),
        .step_cap_mask(phase7_cfg_pkg::STEP_CAP_MASK[step*NC +: NC]),
        .step_cond(phase7_cfg_pkg::STEP_COND[step*3 +: 3]),
        .step_cond_cell(phase7_cfg_pkg::STEP_COND_CELL[step*8 +: 8]),
        .step_cond_arg(phase7_cfg_pkg::STEP_COND_ARG[step*TW +: TW]),
        .step_timeout(phase7_cfg_pkg::STEP_TIMEOUT[step*TW +: TW]),
        .sig_done(sig_done), .cap_done(cap_done), .cap_level(cap_level), .cap_edges(cap_edges),
        .step(step), .run(run), .sig_apply(sig_apply), .cap_apply(cap_apply),
        .busy(busy), .seq_done(seq_done), .fault(fault), .aborted(aborted),
        .last_step(last_step), .step_start(step_start),
        // compile-time table: every step is always there, so no prefetch and never LATE
        .fetch_step(), .fetch_ready(1'b1), .apply_tick(), .late()
    );

    // ---- 5 sig cells, config = the current step's entry ----
    logic [NS-1:0] pin_out;
    logic clk_rise, clk_fall;

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_clk (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[0]),
        .cfg_type(phase7_cfg_pkg::CLK_TYPE[step*3 +: 3]), .cfg_idle_level(phase7_cfg_pkg::CLK_IDLE[step]),
        .cfg_delay(phase7_cfg_pkg::CLK_DELAY[step*TW +: TW]), .cfg_param_a(phase7_cfg_pkg::CLK_PARAM_A[step*TW +: TW]),
        .cfg_param_b(phase7_cfg_pkg::CLK_PARAM_B[step*TW +: TW]), .cfg_cycles(phase7_cfg_pkg::CLK_CYCLES[step*TW +: TW]),
        .cfg_msb_first(phase7_cfg_pkg::CLK_MSB_FIRST[step]), .cfg_data(phase7_cfg_pkg::CLK_DATA[step]),
        .cfg_bits(phase7_cfg_pkg::CLK_BITS[step*TW +: TW]), .shift_strobe(1'b0),
        .pin_out(pin_out[0]), .rising_edge(clk_rise), .falling_edge(clk_fall), .active(), .done(sig_done[0]));

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_rst (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[1]),
        .cfg_type(phase7_cfg_pkg::RST_TYPE[step*3 +: 3]), .cfg_idle_level(phase7_cfg_pkg::RST_IDLE[step]),
        .cfg_delay(phase7_cfg_pkg::RST_DELAY[step*TW +: TW]), .cfg_param_a(phase7_cfg_pkg::RST_PARAM_A[step*TW +: TW]),
        .cfg_param_b(phase7_cfg_pkg::RST_PARAM_B[step*TW +: TW]), .cfg_cycles(phase7_cfg_pkg::RST_CYCLES[step*TW +: TW]),
        .cfg_msb_first(phase7_cfg_pkg::RST_MSB_FIRST[step]), .cfg_data(phase7_cfg_pkg::RST_DATA[step]),
        .cfg_bits(phase7_cfg_pkg::RST_BITS[step*TW +: TW]), .shift_strobe(1'b0),
        .pin_out(pin_out[1]), .rising_edge(), .falling_edge(), .active(), .done(sig_done[1]));

    sig_cell #(.TICK_W(TW), .SERIAL_W(16)) u_data (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[2]),
        .cfg_type(phase7_cfg_pkg::DATA_TYPE[step*3 +: 3]), .cfg_idle_level(phase7_cfg_pkg::DATA_IDLE[step]),
        .cfg_delay(phase7_cfg_pkg::DATA_DELAY[step*TW +: TW]), .cfg_param_a(phase7_cfg_pkg::DATA_PARAM_A[step*TW +: TW]),
        .cfg_param_b(phase7_cfg_pkg::DATA_PARAM_B[step*TW +: TW]), .cfg_cycles(phase7_cfg_pkg::DATA_CYCLES[step*TW +: TW]),
        .cfg_msb_first(phase7_cfg_pkg::DATA_MSB_FIRST[step]), .cfg_data(phase7_cfg_pkg::DATA_DATA[step*16 +: 16]),
        .cfg_bits(phase7_cfg_pkg::DATA_BITS[step*TW +: TW]), .shift_strobe(clk_fall),
        .pin_out(pin_out[2]), .rising_edge(), .falling_edge(), .active(), .done(sig_done[2]));

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_cs (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[3]),
        .cfg_type(phase7_cfg_pkg::CS_TYPE[step*3 +: 3]), .cfg_idle_level(phase7_cfg_pkg::CS_IDLE[step]),
        .cfg_delay(phase7_cfg_pkg::CS_DELAY[step*TW +: TW]), .cfg_param_a(phase7_cfg_pkg::CS_PARAM_A[step*TW +: TW]),
        .cfg_param_b(phase7_cfg_pkg::CS_PARAM_B[step*TW +: TW]), .cfg_cycles(phase7_cfg_pkg::CS_CYCLES[step*TW +: TW]),
        .cfg_msb_first(phase7_cfg_pkg::CS_MSB_FIRST[step]), .cfg_data(phase7_cfg_pkg::CS_DATA[step]),
        .cfg_bits(phase7_cfg_pkg::CS_BITS[step*TW +: TW]), .shift_strobe(1'b0),
        .pin_out(pin_out[3]), .rising_edge(), .falling_edge(), .active(), .done(sig_done[3]));

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_en (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[4]),
        .cfg_type(phase7_cfg_pkg::EN_TYPE[step*3 +: 3]), .cfg_idle_level(phase7_cfg_pkg::EN_IDLE[step]),
        .cfg_delay(phase7_cfg_pkg::EN_DELAY[step*TW +: TW]), .cfg_param_a(phase7_cfg_pkg::EN_PARAM_A[step*TW +: TW]),
        .cfg_param_b(phase7_cfg_pkg::EN_PARAM_B[step*TW +: TW]), .cfg_cycles(phase7_cfg_pkg::EN_CYCLES[step*TW +: TW]),
        .cfg_msb_first(phase7_cfg_pkg::EN_MSB_FIRST[step]), .cfg_data(phase7_cfg_pkg::EN_DATA[step]),
        .cfg_bits(phase7_cfg_pkg::EN_BITS[step*TW +: TW]), .shift_strobe(1'b0),
        .pin_out(pin_out[4]), .rising_edge(), .falling_edge(), .active(), .done(sig_done[4]));

    // ---- FMC pins: 0-4 driven straight from the cells' output FFs, the rest tri-stated ----
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
        if (!rst_n) begin
            in_s0 <= '0; in_s1 <= '0;
        end else begin
            in_s0 <= fmc_pins[16 +: NC];
            in_s1 <= in_s0;
        end
    end

    // ---- 5 cap cells ----
    logic [15:0] data_in_reg;

    cap_cell #(.TICK_W(TW), .CAP_W(1)) u_clk_in (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[0]), .sync_in(in_s1[0]),
        .cfg_mode(phase7_cfg_pkg::CLK_IN_MODE[step*2 +: 2]), .cfg_msb_first(phase7_cfg_pkg::CLK_IN_MSB_FIRST[step]),
        .cfg_bits(phase7_cfg_pkg::CLK_IN_BITS[step*TW +: TW]), .capture_strobe(1'b0),
        .level_out(cap_level[0]), .edge_count(cap_edges[0*TW +: TW]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(), .done(cap_done[0]));

    cap_cell #(.TICK_W(TW), .CAP_W(1)) u_rst_in (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[1]), .sync_in(in_s1[1]),
        .cfg_mode(phase7_cfg_pkg::RST_IN_MODE[step*2 +: 2]), .cfg_msb_first(phase7_cfg_pkg::RST_IN_MSB_FIRST[step]),
        .cfg_bits(phase7_cfg_pkg::RST_IN_BITS[step*TW +: TW]), .capture_strobe(1'b0),
        .level_out(cap_level[1]), .edge_count(cap_edges[1*TW +: TW]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(), .done(cap_done[1]));

    cap_cell #(.TICK_W(TW), .CAP_W(16)) u_data_in (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[2]), .sync_in(in_s1[2]),
        .cfg_mode(phase7_cfg_pkg::DATA_IN_MODE[step*2 +: 2]), .cfg_msb_first(phase7_cfg_pkg::DATA_IN_MSB_FIRST[step]),
        .cfg_bits(phase7_cfg_pkg::DATA_IN_BITS[step*TW +: TW]), .capture_strobe(clk_rise),
        .level_out(cap_level[2]), .edge_count(cap_edges[2*TW +: TW]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(data_in_reg), .done(cap_done[2]));

    cap_cell #(.TICK_W(TW), .CAP_W(1)) u_cs_in (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[3]), .sync_in(in_s1[3]),
        .cfg_mode(phase7_cfg_pkg::CS_IN_MODE[step*2 +: 2]), .cfg_msb_first(phase7_cfg_pkg::CS_IN_MSB_FIRST[step]),
        .cfg_bits(phase7_cfg_pkg::CS_IN_BITS[step*TW +: TW]), .capture_strobe(1'b0),
        .level_out(cap_level[3]), .edge_count(cap_edges[3*TW +: TW]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(), .done(cap_done[3]));

    cap_cell #(.TICK_W(TW), .CAP_W(1)) u_en_in (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[4]), .sync_in(in_s1[4]),
        .cfg_mode(phase7_cfg_pkg::EN_IN_MODE[step*2 +: 2]), .cfg_msb_first(phase7_cfg_pkg::EN_IN_MSB_FIRST[step]),
        .cfg_bits(phase7_cfg_pkg::EN_IN_BITS[step*TW +: TW]), .capture_strobe(1'b0),
        .level_out(cap_level[4]), .edge_count(cap_edges[4*TW +: TW]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(), .done(cap_done[4]));

    // ---- LD6: data_in matched the expected pattern (sticky until the next START) ----
    logic data_ok;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          data_ok <= 1'b0;
        else if (start)      data_ok <= 1'b0;
        else if (cap_done[2]) data_ok <= ((data_in_reg & phase7_cfg_pkg::DATA_IN_EXPECT_MASK)
                                          == phase7_cfg_pkg::DATA_IN_EXPECT);
    end

    logic [SW-1:0] shown_step;
    assign shown_step = busy ? step : last_step;

    assign led[2:0] = shown_step[2:0];
    assign led[3]   = busy;
    assign led[4]   = seq_done;
    assign led[5]   = fault;
    assign led[6]   = data_ok;
    assign led[7]   = aborted;

endmodule
