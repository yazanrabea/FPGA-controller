`timescale 1ns / 1ps
//==========================================================================
// seq_engine_tb
//
// Phase 7.2: seq_engine driving REAL cells: sig0 = a free-running clock set
// only in step 0 (must never restart), sig1 = the pin each step changes,
// cap0 = sig1 looped back through a 2-FF sync (EDGE_COUNT / LEVEL), cap1 =
// a SERIAL capture of sig1 strobed by sig0's rising edge. The step table is
// a set of testbench arrays indexed by the engine's `step` output.
//
// Run A (7 steps), every boundary measured in ticks against the contract in
// seq_engine.sv's header:
//   0 AFTER 7      sig0 CLOCK 10/5 free, sig1 HIGH (idle 1), cap0 EDGE_COUNT, cap1 LEVEL
//   1 DONE sig1    sig1 PULSE width 3 delay 2
//   2 EDGES cap0>=5  sig1 CLOCK 4/2 free, cap0 re-armed
//   3 LEVEL cap0==1  sig1 HIGH, cap0 -> LEVEL
//   4 CAPTURED cap1  sig1 SERIAL 4'b1011 (shift on sig0 falling), cap1 SERIAL 4 bits
//   5 AFTER 1      (no cells)
//   6 AFTER 3      (no cells), last
// Run B: step 3 waits for a level that never comes -> FAULT at step 3.
// Run C: abort in step 2.  Run D: start while busy is ignored.
// Run E: a 1-step table with AFTER 1.
//==========================================================================
module seq_engine_tb;

    localparam int TW = 32;
    localparam int NS = 7;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    int unsigned cyc = 0;
    always @(posedge clk) cyc++;

    // ---- step table (TB variables, so runs B/C can edit them) ----
    logic [1:0]    t_sig_mask [0:NS-1];
    logic [1:0]    t_cap_mask [0:NS-1];
    logic [2:0]    t_cond     [0:NS-1];
    logic [7:0]    t_cell     [0:NS-1];
    logic [TW-1:0] t_arg      [0:NS-1];
    logic [TW-1:0] t_timeout  [0:NS-1];
    // sig1 config per step (sig0 is CLOCK 10/5 in every step, only applied in step 0)
    logic [2:0]    s1_type  [0:NS-1];
    logic          s1_idle  [0:NS-1];
    logic [TW-1:0] s1_delay [0:NS-1], s1_a [0:NS-1], s1_b [0:NS-1], s1_cyc [0:NS-1];
    logic [1:0]    c0_mode  [0:NS-1], c1_mode [0:NS-1];
    logic [4:0]    n_steps;

    // ---- DUT ----
    logic start = 0, abort = 0;
    logic [3:0] step, last_step;
    logic run, busy, seq_done, fault, aborted, step_start;
    logic [1:0] sig_apply, cap_apply;
    logic [1:0] sig_done_v, cap_done_v, cap_level_v;
    logic [2*TW-1:0] cap_edges_v;

    seq_engine #(.N_SIG(2), .N_CAP(2), .TICK_W(TW), .STEP_W(4)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort), .n_steps(n_steps),
        .step_sig_mask(t_sig_mask[step]), .step_cap_mask(t_cap_mask[step]),
        .step_cond(t_cond[step]), .step_cond_cell(t_cell[step]),
        .step_cond_arg(t_arg[step]), .step_timeout(t_timeout[step]),
        .sig_done(sig_done_v), .cap_done(cap_done_v), .cap_level(cap_level_v), .cap_edges(cap_edges_v),
        .step(step), .run(run), .sig_apply(sig_apply), .cap_apply(cap_apply),
        .busy(busy), .seq_done(seq_done), .fault(fault), .aborted(aborted),
        .last_step(last_step), .step_start(step_start)
    );

    // ---- cells ----
    logic p0, p1, r0, f0;
    sig_cell #(.TICK_W(TW), .SERIAL_W(1)) u_sig0 (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[0]),
        .cfg_type(3'd3), .cfg_idle_level(1'b0), .cfg_delay(32'd0), .cfg_param_a(32'd10),
        .cfg_param_b(32'd5), .cfg_cycles(32'd0), .cfg_msb_first(1'b1), .cfg_data(1'b0), .cfg_bits(32'd0),
        .shift_strobe(1'b0),
        .pin_out(p0), .rising_edge(r0), .falling_edge(f0), .active(), .done(sig_done_v[0]));

    sig_cell #(.TICK_W(TW), .SERIAL_W(4)) u_sig1 (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[1]),
        .cfg_type(s1_type[step]), .cfg_idle_level(s1_idle[step]), .cfg_delay(s1_delay[step]),
        .cfg_param_a(s1_a[step]), .cfg_param_b(s1_b[step]), .cfg_cycles(s1_cyc[step]),
        .cfg_msb_first(1'b1), .cfg_data(4'b1011), .cfg_bits(32'd4),
        .shift_strobe(f0),
        .pin_out(p1), .rising_edge(), .falling_edge(), .active(), .done(sig_done_v[1]));

    logic p1_s0, p1_s1;
    always_ff @(posedge clk) begin p1_s0 <= p1; p1_s1 <= p1_s0; end

    logic [3:0] cap1_reg;
    cap_cell #(.TICK_W(TW), .CAP_W(1)) u_cap0 (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[0]), .sync_in(p1_s1),
        .cfg_mode(c0_mode[step]), .cfg_msb_first(1'b1), .cfg_bits(32'd0), .capture_strobe(1'b0),
        .level_out(cap_level_v[0]), .edge_count(cap_edges_v[TW-1:0]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(), .done(cap_done_v[0]));
    cap_cell #(.TICK_W(TW), .CAP_W(4)) u_cap1 (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[1]), .sync_in(p1_s1),
        .cfg_mode(c1_mode[step]), .cfg_msb_first(1'b1), .cfg_bits(32'd4), .capture_strobe(r0),
        .level_out(cap_level_v[1]), .edge_count(cap_edges_v[2*TW-1:TW]), .period_ticks(), .high_ticks(),
        .period_valid(), .capture_reg(cap1_reg), .done(cap_done_v[1]));

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

    // ---- monitors ----
    int unsigned apply_cyc [0:15];
    int          apply_step [0:15];
    int          n_apply;
    int unsigned sig1_done_cyc, edges5_cyc, level1_cyc, cap1_done_cyc, end_cyc;
    int unsigned last_p0_rise;
    int          p0_bad_periods, p0_periods;

    task automatic clear_mon();
        n_apply = 0; sig1_done_cyc = 0; edges5_cyc = 0; level1_cyc = 0; cap1_done_cyc = 0;
        end_cyc = 0; last_p0_rise = 0; p0_bad_periods = 0; p0_periods = 0; fault_cyc = 0;
    endtask

    // Monitors sample at negedge: every DUT register has settled by then, so `cyc` (the
    // number of posedges so far) is the tick a value became visible. Sampling on posedge
    // races the DUT's own register updates (it did: +/-1 tick errors, 2026-10-22).
    int unsigned fault_cyc;
    logic p0_d = 0;
    always @(negedge clk) begin
        if (step_start) begin
            apply_cyc[n_apply] = cyc; apply_step[n_apply] = step; n_apply++;
        end
        if (busy && step == 1 && sig_done_v[1] && sig1_done_cyc == 0) sig1_done_cyc = cyc;
        if (busy && step == 2 && cap_edges_v[TW-1:0] >= 5 && edges5_cyc == 0) edges5_cyc = cyc;
        if (busy && step == 3 && cap_level_v[0] && level1_cyc == 0 && cyc >= apply_cyc[3] + 2) level1_cyc = cyc;
        if (busy && step == 4 && cap_done_v[1] && cap1_done_cyc == 0) cap1_done_cyc = cyc;
        if (fault && fault_cyc == 0) fault_cyc = cyc;
        // sig0 period: every rising edge of the pin while running is 10 ticks after the last
        if (run && p0 && !p0_d) begin
            if (last_p0_rise != 0) begin
                p0_periods++;
                if (cyc - last_p0_rise != 10) p0_bad_periods++;
            end
            last_p0_rise = cyc;
        end
        if (!run) last_p0_rise = 0;
        p0_d = p0;
    end

    task automatic set_table_a();
        n_steps = 7;
        // step 0
        t_sig_mask[0] = 2'b11; t_cap_mask[0] = 2'b11; t_cond[0] = 3'd0; t_cell[0] = 0; t_arg[0] = 7;  t_timeout[0] = 0;
        s1_type[0] = 3'd1; s1_idle[0] = 1; s1_delay[0] = 0; s1_a[0] = 0; s1_b[0] = 0; s1_cyc[0] = 0;
        c0_mode[0] = 2'd1; c1_mode[0] = 2'd0;
        // step 1: PULSE w3 d2, wait done sig1
        t_sig_mask[1] = 2'b10; t_cap_mask[1] = 2'b00; t_cond[1] = 3'd1; t_cell[1] = 1; t_arg[1] = 0; t_timeout[1] = 100;
        s1_type[1] = 3'd2; s1_idle[1] = 0; s1_delay[1] = 2; s1_a[1] = 3; s1_b[1] = 0; s1_cyc[1] = 1;
        c0_mode[1] = 2'd1; c1_mode[1] = 2'd0;
        // step 2: CLOCK 4/2 free, re-arm cap0 EDGE_COUNT, wait edges >= 5
        t_sig_mask[2] = 2'b10; t_cap_mask[2] = 2'b01; t_cond[2] = 3'd3; t_cell[2] = 0; t_arg[2] = 5; t_timeout[2] = 200;
        s1_type[2] = 3'd3; s1_idle[2] = 0; s1_delay[2] = 0; s1_a[2] = 4; s1_b[2] = 2; s1_cyc[2] = 0;
        c0_mode[2] = 2'd1; c1_mode[2] = 2'd0;
        // step 3: HIGH, cap0 -> LEVEL, wait level == 1
        t_sig_mask[3] = 2'b10; t_cap_mask[3] = 2'b01; t_cond[3] = 3'd4; t_cell[3] = 0; t_arg[3] = 1; t_timeout[3] = 50;
        s1_type[3] = 3'd1; s1_idle[3] = 0; s1_delay[3] = 0; s1_a[3] = 0; s1_b[3] = 0; s1_cyc[3] = 0;
        c0_mode[3] = 2'd0; c1_mode[3] = 2'd0;
        // step 4: SERIAL 1011 on sig0 falling, cap1 SERIAL 4 bits on sig0 rising, wait captured
        t_sig_mask[4] = 2'b10; t_cap_mask[4] = 2'b10; t_cond[4] = 3'd2; t_cell[4] = 1; t_arg[4] = 0; t_timeout[4] = 500;
        s1_type[4] = 3'd4; s1_idle[4] = 0; s1_delay[4] = 0; s1_a[4] = 0; s1_b[4] = 0; s1_cyc[4] = 0;
        c0_mode[4] = 2'd0; c1_mode[4] = 2'd3;
        // steps 5, 6: no cells, AFTER 1 and AFTER 3
        t_sig_mask[5] = 2'b00; t_cap_mask[5] = 2'b00; t_cond[5] = 3'd0; t_cell[5] = 0; t_arg[5] = 1; t_timeout[5] = 0;
        t_sig_mask[6] = 2'b00; t_cap_mask[6] = 2'b00; t_cond[6] = 3'd0; t_cell[6] = 0; t_arg[6] = 3; t_timeout[6] = 0;
        for (int k = 5; k < 7; k++) begin
            s1_type[k] = s1_type[4]; s1_idle[k] = s1_idle[4]; s1_delay[k] = s1_delay[4];
            s1_a[k] = s1_a[4]; s1_b[k] = s1_b[4]; s1_cyc[k] = s1_cyc[4];
            c0_mode[k] = c0_mode[4]; c1_mode[k] = c1_mode[4];
        end
    endtask

    task automatic pulse_start();
        start = 1; tick(1); start = 0;
    endtask

    task automatic wait_idle(input int max_cycles);
        int k;
        for (k = 0; k < max_cycles && (busy || start); k++) tick(1);
    endtask

    initial begin
        #(2ms); $display("FAIL: watchdog"); $finish;
    end

    initial begin
        set_table_a();
        clear_mon();
        tick(2); rst_n = 1; tick(4);

        $display("\n== after reset: PRELOAD ==");
        check(!run && !busy, "RUN low and not busy after reset");
        check(p1 == 1'b1, "sig1 pin = step 0's idle level (1, HIGH type), not sig_cell's reset 0");
        check(p0 == 1'b0, "sig0 pin = its idle 0");

        $display("\n== RUN A: 7 steps ==");
        pulse_start();
        wait_idle(2000);
        end_cyc = cyc;
        check(n_apply == 7, $sformatf("7 step starts seen (%0d)", n_apply));
        for (int k = 0; k < 7; k++)
            check(apply_step[k] == k, $sformatf("step start %0d has step=%0d", k, apply_step[k]));
        check(apply_cyc[1] - apply_cyc[0] == 7, $sformatf("step 0 AFTER 7: %0d ticks", apply_cyc[1] - apply_cyc[0]));
        check(sig1_done_cyc != 0 && apply_cyc[2] == sig1_done_cyc + 1,
              $sformatf("step 1 ends the tick after sig1 done (done %0d, next apply %0d)", sig1_done_cyc, apply_cyc[2]));
        check(apply_cyc[2] - apply_cyc[1] == 2 + 3 + 2,
              $sformatf("  ...pulse delay 2 + width 3 + done/apply latency 2 = %0d ticks", apply_cyc[2] - apply_cyc[1]));
        check(edges5_cyc != 0 && apply_cyc[3] == edges5_cyc + 1,
              $sformatf("step 2 ends the tick after cap0 edge count reaches 5 (%0d -> %0d)", edges5_cyc, apply_cyc[3]));
        check(level1_cyc != 0 && apply_cyc[4] == level1_cyc + 1,
              $sformatf("step 3 ends the tick after cap0 level == 1 (%0d -> %0d)", level1_cyc, apply_cyc[4]));
        check(cap1_done_cyc != 0 && apply_cyc[5] == cap1_done_cyc + 1,
              $sformatf("step 4 ends the tick after cap1 captured (%0d -> %0d)", cap1_done_cyc, apply_cyc[5]));
        check(cap1_reg == 4'b1011, $sformatf("cap1 captured sig1's SERIAL 1011 (%b)", cap1_reg));
        check(apply_cyc[6] - apply_cyc[5] == 1, "step 5 AFTER 1: 1 tick");
        check(seq_done && !fault && !aborted && last_step == 6, "seq_done set, no fault/abort, last_step = 6");
        check(p0_periods >= 7 && p0_bad_periods == 0,
              $sformatf("sig0 (applied in step 0 only) never restarted: %0d periods, all 10 ticks", p0_periods));
        tick(3);
        check(!run && p1 == 1'b1 && p0 == 1'b0, "after the last step: RUN low, pins back to step 0's idle (sig1=1, sig0=0)");

        $display("\n== RUN B: step 3 waits for something that never comes ==");
        // cap0 is in LEVEL mode in step 3, so its edge count stays 0: EDGES >= 1000 never holds
        t_cond[3] = 3'd3; t_arg[3] = 1000;
        clear_mon();
        pulse_start();
        wait_idle(2000);
        check(fault && !seq_done && last_step == 3, $sformatf("FAULT at step 3 (fault=%0b done=%0b last=%0d)", fault, seq_done, last_step));
        check(n_apply == 4, $sformatf("no step after the fault started (%0d starts)", n_apply));
        tick(3);  // also lets the negedge monitor record fault_cyc
        check(fault_cyc - apply_cyc[3] == 51,
              $sformatf("fault visible 51 ticks after step 3's apply (timeout 50 + 1 register): %0d", fault_cyc - apply_cyc[3]));
        check(!run && p1 == 1'b1, "after the fault: RUN low, sig1 back to step 0's idle");
        t_cond[3] = 3'd4; t_arg[3] = 1;

        $display("\n== RUN C: abort in step 2 ==");
        clear_mon();
        pulse_start();
        while (step != 2) tick(1);
        tick(3);
        abort = 1; tick(1); abort = 0;
        tick(3);
        check(aborted && !fault && !seq_done && last_step == 2, $sformatf("aborted at step 2 (last=%0d)", last_step));
        check(!run && !busy && p1 == 1'b1, "after abort: RUN low, idle, sig1 = step 0 idle");

        $display("\n== RUN D: start while busy is ignored ==");
        clear_mon();
        pulse_start();
        while (step != 2) tick(1);
        pulse_start();
        wait_idle(2000);
        check(seq_done && n_apply == 7, $sformatf("sequence completed once, 7 step starts (%0d), not restarted", n_apply));

        $display("\n== RUN E: 1-step table, AFTER 1 ==");
        n_steps = 1; t_arg[0] = 1;
        clear_mon();
        pulse_start();
        wait_idle(50);
        tick(2);
        check(seq_done && last_step == 0 && n_apply == 1 && !run, "1-step, 1-tick sequence completes");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
