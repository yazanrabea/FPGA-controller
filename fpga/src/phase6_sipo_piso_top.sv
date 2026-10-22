`timescale 1ns / 1ps
//==========================================================================
// phase6_sipo_piso_top
//
// generic_controller_prompt.md §3 Phase 6: SIPO load and PISO read built
// only from the generic cells (no dedicated SIPO/PISO engine), configured
// at compile time from fpga/src/gen/phase6_cfg_pkg.sv (gen_svh.py --phase6
// from config/phase6_sipo_piso.yaml, timing-checked by sipo_piso.py before
// it is written).
//
// SIMULATION TOP ONLY, no XDC: the chip pins are plain ports because there
// is no chip-pin -> FMC LA_P map yet (config/nemo_config.yaml pin_map is all
// null). Don't invent one; a hardware top wraps this once the map exists.
//
// SIPO_LOAD (one RUN):
//   rst_sipo  sig_cell PULSE, idle high (active-low reset), at RUN
//   clk_sipo  sig_cell CLOCK, 136 cycles, starts in its high phase -> exactly
//             136 rising edges (sipo.sv shifts on posedge), ends low
//   sipo_in   sig_cell SERIAL, SERIAL_W = 136, MSB first. shift_strobe =
//             clk_sipo's falling_edge (or rising_edge, SIPO_IN_SHIFT_ON_FALLING
//             = 0): the next bit appears 1 tick after clk_sipo falls, half a
//             period away from the rising edge the chip samples on. Starts a
//             couple of ticks before clk_sipo so bit 135 is set up for edge 1.
//   cs        sig_cell PULSE after the last clk_sipo falling edge; its rising
//             edge is sipo.sv's clk_s (latches parallel_out)
// PISO_READ (same RUN, independent pins):
//   rst_piso  sig_cell HIGH (reset held inactive, idle high too)
//   clk_piso  sig_cell CLOCK, 168 cycles: rising edge 1 loads (shift=0),
//             edges 2..168 shift
//   shift     sig_cell PULSE, rises inside clk_piso's first low phase and
//             stays high past edge 168 (piso2 load: 1 = shift)
//   piso_out  2-FF sync -> cap_cell SERIAL, CAP_W = 168, MSB first.
//             capture_strobe = clk_piso's falling_edge (or rising_edge,
//             PISO_OUT_CAPTURE_ON_FALLING = 0): falling edge 1 samples bit 1
//             right after the load edge, before any shift. The sampled value
//             is the pad ~2 ticks earlier (sync latency), which is why
//             sipo_piso.check_piso_read requires clk_piso high >= 3 ticks +
//             chip delay.
// Every driven pin comes straight from a sig_cell's registered pin_out, so
// clk_sipo, cs and clk_piso (clocks inside the chip) can't glitch.
//
// The strobe edge selects are compile-time constants from the package; the
// edges themselves are UNCONFIRMED (Dima).
//==========================================================================
module phase6_sipo_piso_top (
    input  logic         clk,          // 100 MHz timebase, 1 cycle = 1 tick
    input  logic         rst_n,        // async reset, active low
    input  logic         run_set,      // -> run_ctrl (rising edge = RUN)
    input  logic         run_clear,    // -> run_ctrl (rising edge = STOP)
    input  logic         apply_cmd,    // -> run_ctrl (rising edge = APPLY the compile-time config)

    // chip pins
    output logic         rst_sipo,
    output logic         clk_sipo,
    output logic         sipo_in,
    output logic         cs,
    output logic         rst_piso,
    output logic         clk_piso,
    output logic         shift,
    input  logic         piso_out,     // asynchronous chip output

    output logic                                  run,
    output logic                                  sipo_done,     // 1-cycle: all 136 bits shifted out
    output logic [phase6_cfg_pkg::PISO_BITS-1:0]  piso_frame,    // captured frame, first bit = MSB
    output logic                                  piso_done      // 1-cycle: 168 bits captured
);

    // explicit phase6_cfg_pkg:: scoping, not a wildcard import (Icarus mis-sizes
    // wildcard-imported localparams on port connections, see phase4_loopback_top.sv)
    localparam int TW = phase6_cfg_pkg::TICK_W;

    logic apply;
    run_ctrl u_run_ctrl (
        .clk(clk), .rst_n(rst_n),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd),
        .run(run), .apply(apply)
    );

    // edge strobes of the two serial clocks (1 cycle, same cycle the pin changes)
    logic clk_sipo_rise, clk_sipo_fall, clk_piso_rise, clk_piso_fall;
    logic sipo_shift_strobe, piso_capture_strobe;
    assign sipo_shift_strobe   = phase6_cfg_pkg::SIPO_IN_SHIFT_ON_FALLING    ? clk_sipo_fall : clk_sipo_rise;
    assign piso_capture_strobe = phase6_cfg_pkg::PISO_OUT_CAPTURE_ON_FALLING ? clk_piso_fall : clk_piso_rise;

    // ---------------- SIPO_LOAD ----------------
    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_rst_sipo (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::RST_SIPO_TYPE), .cfg_idle_level(phase6_cfg_pkg::RST_SIPO_IDLE),
        .cfg_delay(phase6_cfg_pkg::RST_SIPO_DELAY), .cfg_param_a(phase6_cfg_pkg::RST_SIPO_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::RST_SIPO_PARAM_B), .cfg_cycles(phase6_cfg_pkg::RST_SIPO_CYCLES),
        .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(phase6_cfg_pkg::RST_SIPO_BITS),
        .shift_strobe(1'b0),
        .pin_out(rst_sipo), .rising_edge(), .falling_edge(), .active(), .done()
    );

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_clk_sipo (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::CLK_SIPO_TYPE), .cfg_idle_level(phase6_cfg_pkg::CLK_SIPO_IDLE),
        .cfg_delay(phase6_cfg_pkg::CLK_SIPO_DELAY), .cfg_param_a(phase6_cfg_pkg::CLK_SIPO_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::CLK_SIPO_PARAM_B), .cfg_cycles(phase6_cfg_pkg::CLK_SIPO_CYCLES),
        .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(phase6_cfg_pkg::CLK_SIPO_BITS),
        .shift_strobe(1'b0),
        .pin_out(clk_sipo), .rising_edge(clk_sipo_rise), .falling_edge(clk_sipo_fall),
        .active(), .done()
    );

    sig_cell #(.TICK_W(TW), .SERIAL_W(phase6_cfg_pkg::SIPO_BITS)) u_sipo_in (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::SIPO_IN_TYPE), .cfg_idle_level(phase6_cfg_pkg::SIPO_IN_IDLE),
        .cfg_delay(phase6_cfg_pkg::SIPO_IN_DELAY), .cfg_param_a(phase6_cfg_pkg::SIPO_IN_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::SIPO_IN_PARAM_B), .cfg_cycles(phase6_cfg_pkg::SIPO_IN_CYCLES),
        .cfg_msb_first(phase6_cfg_pkg::SIPO_IN_MSB_FIRST), .cfg_data(phase6_cfg_pkg::SIPO_IN_DATA),
        .cfg_bits(phase6_cfg_pkg::SIPO_IN_BITS),
        .shift_strobe(sipo_shift_strobe),
        .pin_out(sipo_in), .rising_edge(), .falling_edge(), .active(), .done(sipo_done)
    );

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_cs (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::CS_TYPE), .cfg_idle_level(phase6_cfg_pkg::CS_IDLE),
        .cfg_delay(phase6_cfg_pkg::CS_DELAY), .cfg_param_a(phase6_cfg_pkg::CS_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::CS_PARAM_B), .cfg_cycles(phase6_cfg_pkg::CS_CYCLES),
        .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(phase6_cfg_pkg::CS_BITS),
        .shift_strobe(1'b0),
        .pin_out(cs), .rising_edge(), .falling_edge(), .active(), .done()
    );

    // ---------------- PISO_READ ----------------
    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_rst_piso (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::RST_PISO_TYPE), .cfg_idle_level(phase6_cfg_pkg::RST_PISO_IDLE),
        .cfg_delay(phase6_cfg_pkg::RST_PISO_DELAY), .cfg_param_a(phase6_cfg_pkg::RST_PISO_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::RST_PISO_PARAM_B), .cfg_cycles(phase6_cfg_pkg::RST_PISO_CYCLES),
        .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(phase6_cfg_pkg::RST_PISO_BITS),
        .shift_strobe(1'b0),
        .pin_out(rst_piso), .rising_edge(), .falling_edge(), .active(), .done()
    );

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_clk_piso (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::CLK_PISO_TYPE), .cfg_idle_level(phase6_cfg_pkg::CLK_PISO_IDLE),
        .cfg_delay(phase6_cfg_pkg::CLK_PISO_DELAY), .cfg_param_a(phase6_cfg_pkg::CLK_PISO_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::CLK_PISO_PARAM_B), .cfg_cycles(phase6_cfg_pkg::CLK_PISO_CYCLES),
        .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(phase6_cfg_pkg::CLK_PISO_BITS),
        .shift_strobe(1'b0),
        .pin_out(clk_piso), .rising_edge(clk_piso_rise), .falling_edge(clk_piso_fall),
        .active(), .done()
    );

    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_shift (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(phase6_cfg_pkg::SHIFT_TYPE), .cfg_idle_level(phase6_cfg_pkg::SHIFT_IDLE),
        .cfg_delay(phase6_cfg_pkg::SHIFT_DELAY), .cfg_param_a(phase6_cfg_pkg::SHIFT_PARAM_A),
        .cfg_param_b(phase6_cfg_pkg::SHIFT_PARAM_B), .cfg_cycles(phase6_cfg_pkg::SHIFT_CYCLES),
        .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(phase6_cfg_pkg::SHIFT_BITS),
        .shift_strobe(1'b0),
        .pin_out(shift), .rising_edge(), .falling_edge(), .active(), .done()
    );

    // 2-FF synchronizer on the asynchronous chip output (CLAUDE.md §8)
    logic piso_out_s0, piso_out_s1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            piso_out_s0 <= 1'b0;
            piso_out_s1 <= 1'b0;
        end else begin
            piso_out_s0 <= piso_out;
            piso_out_s1 <= piso_out_s0;
        end
    end

    cap_cell #(.TICK_W(TW), .CAP_W(phase6_cfg_pkg::PISO_BITS)) u_piso_out (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .sync_in(piso_out_s1),
        .cfg_mode(phase6_cfg_pkg::PISO_OUT_CAP_MODE), .cfg_msb_first(phase6_cfg_pkg::PISO_OUT_MSB_FIRST),
        .cfg_bits(phase6_cfg_pkg::PISO_OUT_BITS),
        .capture_strobe(piso_capture_strobe),
        .level_out(), .edge_count(), .period_ticks(), .high_ticks(), .period_valid(),
        .capture_reg(piso_frame), .done(piso_done)
    );

endmodule
