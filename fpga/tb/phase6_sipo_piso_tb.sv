`timescale 1ns / 1ps
//==========================================================================
// phase6_sipo_piso_tb
//
// Phase 6.4: our controller (phase6_sipo_piso_top) driving Dima's
// UNMODIFIED RTL from fpga/reference/dima_blocks/ -- sipo_wrapper (+ sipo)
// on the SIPO pins, four chained piso2 on the PISO pins -- with the Tower
// cells stubbed (fpga/tb/tower_cell_stubs.sv). Expected values come from
// phase6_cfg_pkg (gen_svh.py --phase6), i.e. from the same Python model
// the config was checked against.
//
// Chip-side glue the testbench provides (there is no chip netlist):
//   * phirst is driven by the testbench (on the chip it comes from the
//     on-chip clock generator, docs/controller_spec.md Q4).
//   * PISO chain per piso.sv's header: PISO3.prev = 0, PISOk.prev =
//     PISO(k+1).serial_out, read PISO0.serial_out.
//   * One lumped transport delay (chip_delay_ns) from PISO0.serial_out to
//     the piso_out pad: clk-to-q + the 4 DLY3 cells + wiring, all unknown.
//
// Three RUNs of the same compile-time config (one APPLY, then RUN/STOP):
//   1. chip delay 0 ns       -> frames correct
//   2. chip delay 400 ns     -> frames correct (rule allows up to 470 ns at
//                               1 MHz: high 50 ticks - 3 sync ticks)
//   3. chip delay 600 ns     -> PISO frame WRONG, as check_piso_read predicts
//                               (shows the rule's boundary in real RTL, and
//                               that the frame check can fail)
// Each RUN also re-checks Dima's quirks as written: before the first phirst,
// sel[23:8] holds the PREVIOUS load's slice 0 (0 on the first load) -- the
// reset branch reads parallel_out before sipo.sv's reset clears it (Q1) --
// and an 8th phirst reads past bit 135 (Q2, X in sim).
//==========================================================================
module phase6_sipo_piso_tb;

    localparam int SB = phase6_cfg_pkg::SIPO_BITS;
    localparam int PB = phase6_cfg_pkg::PISO_BITS;

    logic clk = 0, rst_n = 0;
    logic run_set = 0, run_clear = 0, apply_cmd = 0;
    always #5 clk = ~clk;  // 100 MHz

    // ---- DUT ----
    logic rst_sipo, clk_sipo, sipo_in, cs, rst_piso, clk_piso, shift, piso_out;
    logic run, sipo_done, piso_done;
    logic [PB-1:0] piso_frame;

    phase6_sipo_piso_top dut (
        .clk(clk), .rst_n(rst_n),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd),
        .rst_sipo(rst_sipo), .clk_sipo(clk_sipo), .sipo_in(sipo_in), .cs(cs),
        .rst_piso(rst_piso), .clk_piso(clk_piso), .shift(shift), .piso_out(piso_out),
        .run(run), .sipo_done(sipo_done), .piso_frame(piso_frame), .piso_done(piso_done)
    );

    // ---- Dima's SIPO ----
    logic phirst = 0;
    logic [23:0] sel;
    logic sipo_out;
    sipo_wrapper #(.WL_num(16), .BL_num(8)) u_dima_sipo (
        .clk(clk_sipo), .rst_n(rst_sipo), .serial_in(sipo_in), .clk_s(cs),
        .phirst(phirst), .sel(sel), .sipo_out(sipo_out)
    );

    // ---- Dima's PISO chain: PISO0 <- PISO1 <- PISO2 <- PISO3 <- 0 ----
    logic [3:0] ser;
    piso2 u_piso0 (.clk(clk_piso), .rst_n(rst_piso), .load(shift),
        .out0(phase6_cfg_pkg::PISO_TB_STAGE0_OUT0), .out1(phase6_cfg_pkg::PISO_TB_STAGE0_OUT1),
        .tdc_out0(phase6_cfg_pkg::PISO_TB_STAGE0_TDC_OUT0), .tdc_out1(phase6_cfg_pkg::PISO_TB_STAGE0_TDC_OUT1),
        .prev_serial_bit(ser[1]), .serial_out(ser[0]));
    piso2 u_piso1 (.clk(clk_piso), .rst_n(rst_piso), .load(shift),
        .out0(phase6_cfg_pkg::PISO_TB_STAGE1_OUT0), .out1(phase6_cfg_pkg::PISO_TB_STAGE1_OUT1),
        .tdc_out0(phase6_cfg_pkg::PISO_TB_STAGE1_TDC_OUT0), .tdc_out1(phase6_cfg_pkg::PISO_TB_STAGE1_TDC_OUT1),
        .prev_serial_bit(ser[2]), .serial_out(ser[1]));
    piso2 u_piso2 (.clk(clk_piso), .rst_n(rst_piso), .load(shift),
        .out0(phase6_cfg_pkg::PISO_TB_STAGE2_OUT0), .out1(phase6_cfg_pkg::PISO_TB_STAGE2_OUT1),
        .tdc_out0(phase6_cfg_pkg::PISO_TB_STAGE2_TDC_OUT0), .tdc_out1(phase6_cfg_pkg::PISO_TB_STAGE2_TDC_OUT1),
        .prev_serial_bit(ser[3]), .serial_out(ser[2]));
    piso2 u_piso3 (.clk(clk_piso), .rst_n(rst_piso), .load(shift),
        .out0(phase6_cfg_pkg::PISO_TB_STAGE3_OUT0), .out1(phase6_cfg_pkg::PISO_TB_STAGE3_OUT1),
        .tdc_out0(phase6_cfg_pkg::PISO_TB_STAGE3_TDC_OUT0), .tdc_out1(phase6_cfg_pkg::PISO_TB_STAGE3_TDC_OUT1),
        .prev_serial_bit(1'b0), .serial_out(ser[3]));

    // lumped chip delay, transport (every edge kept)
    int chip_delay_ns = 0;
    initial piso_out = 1'b0;
    always @(ser[0]) piso_out <= #(chip_delay_ns) ser[0];

    // ---- checks ----
    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    task automatic tick(input int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    // ---- monitors, cleared at the start of every RUN ----
    int clk_sipo_rises, cs_rises, clk_piso_rises, shift_high_at_edge, shift_at_edge1;
    logic [SB-1:0] sipo_seen;          // sipo_in as sampled on clk_sipo rising edges
    realtime rst_sipo_release, first_clk_sipo_rise;
    logic sipo_done_seen, piso_done_seen;

    task automatic clear_monitors();
        clk_sipo_rises = 0; cs_rises = 0; clk_piso_rises = 0;
        shift_high_at_edge = 0; shift_at_edge1 = -1;
        sipo_seen = '0; rst_sipo_release = -1; first_clk_sipo_rise = -1;
        sipo_done_seen = 0; piso_done_seen = 0;
    endtask

    always @(posedge clk_sipo) begin
        if (clk_sipo_rises == 0) first_clk_sipo_rise = $realtime;
        clk_sipo_rises++;
        sipo_seen = {sipo_seen[SB-2:0], sipo_in};
    end
    always @(posedge rst_sipo) rst_sipo_release = $realtime;
    always @(posedge cs) cs_rises++;
    always @(posedge clk_piso) begin
        clk_piso_rises++;
        if (clk_piso_rises == 1) shift_at_edge1 = shift;
        if (shift) shift_high_at_edge++;
    end
    always @(posedge clk) begin
        if (sipo_done) sipo_done_seen = 1;
        if (piso_done) piso_done_seen = 1;
    end

    task automatic pulse_phirst();
        #20 phirst = 1;
        #20 phirst = 0;
        #1;
    endtask

    task automatic one_run(input int delay_ns, input logic expect_piso_ok);
        int k;
        logic [15:0] prev_slice0;
        logic [23:0] exp_sel [0:7];
        exp_sel[0] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_0; exp_sel[1] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_1;
        exp_sel[2] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_2; exp_sel[3] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_3;
        exp_sel[4] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_4; exp_sel[5] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_5;
        exp_sel[6] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_6; exp_sel[7] = phase6_cfg_pkg::SIPO_TB_SEL_AFTER_7;

        // Q1: rst_sipo's reset branch copies parallel_out[23:8] as it is *before* the
        // reset, so sel[23:8] starts at the previous load's slice 0 (0 on the first load).
        prev_slice0 = u_dima_sipo.u_sipo.parallel_out[23:8];
        exp_sel[0] = {prev_slice0, phase6_cfg_pkg::SIPO_TB_SEL_AFTER_0[7:0]};

        chip_delay_ns = delay_ns;
        clear_monitors();
        run_set = 1; tick(4); run_set = 0;

        // ---- SIPO_LOAD: wait for the cs pulse to finish ----
        @(negedge cs); tick(2);
        $display("  -- SIPO_LOAD --");
        check(clk_sipo_rises == SB, $sformatf("clk_sipo gave %0d rising edges (want %0d)", clk_sipo_rises, SB));
        check(cs_rises == 1, $sformatf("exactly one cs rising edge (%0d)", cs_rises));
        check(rst_sipo_release >= 0 && rst_sipo_release < first_clk_sipo_rise,
              $sformatf("rst_sipo released (%0t) before clk_sipo edge 1 (%0t)", rst_sipo_release, first_clk_sipo_rise));
        check(sipo_seen == phase6_cfg_pkg::SIPO_IN_DATA, "sipo_in sampled on clk_sipo rising edges == SIPO_IN_DATA, MSB first");
        check(sipo_done_seen, "sig_cell sipo_in reports all 136 bits sent");
        check(u_dima_sipo.u_sipo.parallel_out == phase6_cfg_pkg::SIPO_IN_DATA,
              $sformatf("Dima's sipo parallel_out latched by cs == frame (%h)", u_dima_sipo.u_sipo.parallel_out));
        check(sel == exp_sel[0], $sformatf("sel=%h before phirst: sel[23:8] = previous load's slice 0 (%h), not this frame's (Q1 as written)", sel, prev_slice0));
        for (k = 1; k < 8; k++) begin
            pulse_phirst();
            check(sel == exp_sel[k], $sformatf("sel=%h after phirst %0d (want %h)", sel, k, exp_sel[k]));
        end
        pulse_phirst();
        check($isunknown(sel[23:8]) && sel[7:0] == exp_sel[0][7:0],
              $sformatf("phirst 8 reads past bit 135: sel[23:8]=%h (Q2 as written)", sel[23:8]));

        // ---- PISO_READ: wait for the capture (or give up) ----
        // polling loop, not fork/join_any + disable: that crashes Icarus 12's vvp
        for (k = 0; k < 40_000 && !piso_done_seen; k++) tick(1);
        tick(2);
        $display("  -- PISO_READ (chip delay %0d ns) --", delay_ns);
        check(piso_done_seen, "cap_cell captured 168 bits");
        check(clk_piso_rises == PB, $sformatf("clk_piso gave %0d rising edges (want %0d)", clk_piso_rises, PB));
        check(shift_at_edge1 == 0, "shift=0 at clk_piso edge 1 (load)");
        check(shift_high_at_edge == PB - 1, $sformatf("shift=1 at %0d edges (want %0d shift edges)", shift_high_at_edge, PB - 1));
        if (expect_piso_ok) begin
            check(piso_frame == phase6_cfg_pkg::PISO_TB_FRAME,
                  $sformatf("captured frame %h == PISO_TB_FRAME", piso_frame));
            check(piso_frame[PB-1 -: 14] == phase6_cfg_pkg::PISO_TB_STAGE0_OUT1, "first 14 bits = PISO0 out1");
            check(piso_frame[6:0] == phase6_cfg_pkg::PISO_TB_STAGE3_TDC_OUT0, "last 7 bits = PISO3 tdc_out0");
        end else begin
            check(piso_frame != phase6_cfg_pkg::PISO_TB_FRAME,
                  $sformatf("captured frame %h != PISO_TB_FRAME, as check_piso_read predicts", piso_frame));
        end

        // ---- STOP: every pin back to idle ----
        run_clear = 1; tick(4); run_clear = 0; tick(2);
        check(!run && rst_sipo && !clk_sipo && !sipo_in && !cs && rst_piso && !clk_piso && !shift,
              "after STOP: rst_sipo/rst_piso high, every other pin low");
    endtask

    initial begin
        #(3ms);
        $display("FAIL: watchdog timeout");
        $finish;
    end

    initial begin
        tick(3);
        rst_n = 1;
        tick(3);
        // Before the first APPLY every sig_cell drives its reset value, 0 -- so the
        // active-low chip resets are ASSERTED until the config is applied (recorded in
        // docs/issues.md as an open power-up item for Phase 8, not changed here).
        check(!rst_sipo && !rst_piso && !clk_sipo && !sipo_in && !cs && !clk_piso && !shift,
              "before APPLY: every pin 0 (sig_cell reset value; chip resets asserted)");
        apply_cmd = 1; tick(4); apply_cmd = 0; tick(4);
        check(rst_sipo && rst_piso && !clk_sipo && !cs && !shift,
              "after APPLY, before RUN: resets idle high (inactive), clocks/cs/shift low");

        $display("\n== RUN 1: chip delay 0 ns ==");
        one_run(0, 1'b1);
        $display("\n== RUN 2: same config, no new APPLY, chip delay 400 ns ==");
        one_run(400, 1'b1);
        $display("\n== RUN 3: chip delay 600 ns > clk_piso high time - sync (470 ns) ==");
        one_run(600, 1'b0);

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
