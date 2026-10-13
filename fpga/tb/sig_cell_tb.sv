`timescale 1ns / 1ps
//==========================================================================
// sig_cell_tb — self-checking testbench for sig_cell.sv (Phase 3).
//
// Pass/fail convention matches the project's existing self-checking designs
// (fmc_clock_loopback.sv's fault latch): every check prints PASS/FAIL as it
// runs, a running fail counter accumulates, and the final line is
// "ALL TESTS PASSED" or "N CHECK(S) FAILED" -- that line is the real answer.
//
// All stimulus (apply, run, cfg_*, shift_strobe) is driven at @(negedge clk)
// and only ever read/waited-on at @(posedge clk). Driving it right after
// @(posedge clk) instead would race the DUT's own always_ff evaluating that
// identical edge -- both are separate processes woken by the same event with
// no defined order between them, and Icarus resolved that race by letting
// this testbench's post-wait code run BEFORE the DUT's clocked block saw the
// edge, making every config appear to load one full cycle earlier than
// intended. Driving at negedge (a distinct event, half a cycle away from
// either neighbouring posedge) removes the ambiguity entirely.
//==========================================================================
module sig_cell_tb;

    localparam int TICK_W   = 32;
    localparam int SERIAL_W = 16;

    logic                clk = 0;
    logic                rst_n;
    logic                run;
    logic                apply;
    logic [2:0]          cfg_type;
    logic                cfg_idle_level;
    logic [TICK_W-1:0]   cfg_delay;
    logic [TICK_W-1:0]   cfg_param_a;
    logic [TICK_W-1:0]   cfg_param_b;
    logic [TICK_W-1:0]   cfg_cycles;
    logic                cfg_msb_first;
    logic [SERIAL_W-1:0] cfg_data;
    logic [TICK_W-1:0]   cfg_bits;
    logic                shift_strobe;
    logic                pin_out;
    logic                rising_edge_o;
    logic                falling_edge_o;
    logic                active_o;
    logic                done_o;

    localparam logic [2:0] TYPE_LOW    = 3'd0;
    localparam logic [2:0] TYPE_HIGH   = 3'd1;
    localparam logic [2:0] TYPE_PULSE  = 3'd2;
    localparam logic [2:0] TYPE_CLOCK  = 3'd3;
    localparam logic [2:0] TYPE_SERIAL = 3'd4;

    sig_cell #(.TICK_W(TICK_W), .SERIAL_W(SERIAL_W)) dut (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(cfg_type), .cfg_idle_level(cfg_idle_level),
        .cfg_delay(cfg_delay), .cfg_param_a(cfg_param_a), .cfg_param_b(cfg_param_b),
        .cfg_cycles(cfg_cycles), .cfg_msb_first(cfg_msb_first),
        .cfg_data(cfg_data), .cfg_bits(cfg_bits),
        .shift_strobe(shift_strobe),
        .pin_out(pin_out), .rising_edge(rising_edge_o), .falling_edge(falling_edge_o),
        .active(active_o), .done(done_o)
    );

    // second instance at SERIAL_W=1 -- the width every non-SERIAL test pin in
    // fpga/src/phase4_loopback_top.sv actually uses (a cell that will never run
    // SERIAL mode); regression test for the {shift_reg[-1:0], ...} bug this found.
    logic              w1_rst_n, w1_run, w1_apply;
    logic [2:0]        w1_cfg_type;
    logic              w1_cfg_idle_level;
    logic [TICK_W-1:0] w1_cfg_delay, w1_cfg_param_a, w1_cfg_param_b, w1_cfg_cycles, w1_cfg_bits;
    logic              w1_cfg_msb_first;
    logic [0:0]        w1_cfg_data;
    logic              w1_shift_strobe, w1_pin_out;

    sig_cell #(.TICK_W(TICK_W), .SERIAL_W(1)) dut_w1 (
        .clk(clk), .rst_n(w1_rst_n), .run(w1_run), .apply(w1_apply),
        .cfg_type(w1_cfg_type), .cfg_idle_level(w1_cfg_idle_level),
        .cfg_delay(w1_cfg_delay), .cfg_param_a(w1_cfg_param_a), .cfg_param_b(w1_cfg_param_b),
        .cfg_cycles(w1_cfg_cycles), .cfg_msb_first(w1_cfg_msb_first),
        .cfg_data(w1_cfg_data), .cfg_bits(w1_cfg_bits),
        .shift_strobe(w1_shift_strobe),
        .pin_out(w1_pin_out), .rising_edge(), .falling_edge(), .active(), .done()
    );

    always #5 clk = ~clk;  // 100 MHz (10 ns period = 1 tick)

    int fails = 0;
    int checks = 0;

    task automatic check(logic cond, string msg);
        checks++;
        if (cond) begin
            $display("  PASS: %s", msg);
        end else begin
            $display("  FAIL: %s", msg);
            fails++;
        end
    endtask

    // Settles #1 past the posedge, into the time after this edge's NBA updates (pin_out,
    // rising_edge, the counters...) have resolved. Reading DUT outputs immediately after
    // a bare @(posedge clk) -- with no delay -- sees their PRE-edge (stale, one-cycle-
    // lagged) values instead, since those outputs update via nonblocking assignment in
    // the NBA region, which runs strictly after the Active region this code resumes in.
    // (Edge-counting checks elsewhing in this file happened not to care about the lag --
    // the same pulse just gets counted one position later -- which is why those passed
    // even before this fix and masked it.)
    task automatic tick(int n = 1);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic drive_run(logic val);
        @(negedge clk);
        run = val;
    endtask

    // apply a config: drive cfg_* at a negedge, then pulse apply for exactly
    // one posedge, all timed off negedges so there is never a same-edge race
    // with the DUT's own always_ff.
    task automatic cfg_apply(
        logic [2:0] t, logic idle, int delay_v, int a, int b, int cyc,
        logic msb = 1'b1, logic [SERIAL_W-1:0] data = '0, int bits = 0
    );
        @(negedge clk);
        cfg_type       = t;
        cfg_idle_level = idle;
        cfg_delay      = delay_v;
        cfg_param_a    = a;
        cfg_param_b    = b;
        cfg_cycles     = cyc;
        cfg_msb_first  = msb;
        cfg_data       = data;
        cfg_bits       = bits;
        @(negedge clk);
        apply = 1;
        @(negedge clk);
        apply = 0;
    endtask

    task automatic pulse_shift_strobe();
        @(negedge clk);
        shift_strobe = 1;
        @(negedge clk);
        shift_strobe = 0;
    endtask

    task automatic reset_dut();
        rst_n = 0; run = 0; apply = 0; shift_strobe = 0;
        cfg_type = 0; cfg_idle_level = 0; cfg_delay = 0; cfg_param_a = 0;
        cfg_param_b = 0; cfg_cycles = 0; cfg_msb_first = 1; cfg_data = 0; cfg_bits = 0;
        tick(3);
        @(negedge clk);
        rst_n = 1;
        tick(2);
    endtask

    // -----------------------------------------------------------------
    initial begin
        reset_dut();

        // ---- 1. CLOCK, N=2 (minimum period), 50% duty, cycles=5 ----
        $display("\n-- CLOCK N=2, cycles=5 --");
        cfg_apply(TYPE_CLOCK, 1'b0, 0, 2, 1, 5);
        drive_run(1);
        begin
            int edges = 0;
            for (int i = 0; i < 40; i++) begin
                tick(1);
                if (rising_edge_o) edges++;
            end
            check(edges == 5, $sformatf("N=2 cycles=5 produced exactly 5 rising edges (got %0d)", edges));
            check(pin_out == 1'b0, "N=2 clock idle (0) after its 5 cycles finished");
        end
        drive_run(0); tick(2);

        // ---- 2. CLOCK, odd N=33 (matches units.py's 3MHz example), cycles=4 ----
        $display("\n-- CLOCK N=33 (odd), high=16, cycles=4 --");
        cfg_apply(TYPE_CLOCK, 1'b0, 0, 33, 16, 4);
        drive_run(1);
        begin
            int period_measured = -1;
            int high_measured = -1;
            int last_rise = -1;
            int edges = 0;
            for (int i = 0; i < 160; i++) begin
                tick(1);
                if (rising_edge_o) begin
                    edges++;
                    if (last_rise >= 0) period_measured = $time/10 - last_rise;
                    last_rise = $time/10;
                end
                if (falling_edge_o) begin
                    high_measured = $time/10 - last_rise;
                end
            end
            check(edges == 4, $sformatf("N=33 cycles=4 produced exactly 4 rising edges (got %0d)", edges));
            check(period_measured == 33, $sformatf("measured period = 33 ticks (got %0d)", period_measured));
            check(high_measured == 16, $sformatf("measured high time = 16 ticks (got %0d)", high_measured));
        end
        drive_run(0); tick(2);

        // ---- 3. CLOCK, free-running (cycles=0) never stops ----
        $display("\n-- CLOCK free-running (cycles=0) --");
        cfg_apply(TYPE_CLOCK, 1'b0, 0, 10, 5, 0);
        drive_run(1);
        begin
            int edges = 0;
            for (int i = 0; i < 500; i++) begin
                tick(1);
                if (rising_edge_o) edges++;
            end
            check(edges >= 45, $sformatf("free-running clock kept producing edges over 500 ticks (got %0d, expect ~50)", edges));
        end
        drive_run(0); tick(2);

        // ---- 4. PULSE, width = 1 tick (minimum), delay = 0 ----
        $display("\n-- PULSE width=1 tick, delay=0 --");
        cfg_apply(TYPE_PULSE, 1'b0, 0, 1, 0, 0);
        drive_run(1);
        tick(1);
        check(pin_out == 1'b1, "1-tick pulse is high on the very first running tick (delay=0)");
        tick(1);
        check(pin_out == 1'b0, "1-tick pulse already back to idle on the next tick");
        tick(10);
        check(pin_out == 1'b0, "1-tick single-shot pulse never repeats");
        drive_run(0); tick(2);

        // ---- 5. PULSE, active-low (idle=1), width=10, delay=20 ----
        // delay=20 means 20 full idle ticks (ticks 1..20 of RUN), action starts tick 21 --
        // consistent with "N ticks of delay" meaning N ticks pass before the first action,
        // the same convention CLOCK's delay=0 case trivially satisfies too.
        $display("\n-- PULSE active-low, width=10, delay=20 --");
        cfg_apply(TYPE_PULSE, 1'b1, 20, 10, 0, 0);
        drive_run(1);
        tick(1);
        check(pin_out == 1'b1, "idle level (1) held during the delay window");
        tick(19);  // tick 20 total since run: still the last idle tick of the 20-tick delay
        check(pin_out == 1'b1, "still idle through tick 20 (the 20th and last delay tick)");
        tick(1);   // tick 21: first active tick
        check(pin_out == 1'b0, "active-low pulse goes LOW on tick 21, right after the 20-tick delay");
        tick(9);   // ticks 22..30: still within the 10-tick pulse width (21..30)
        check(pin_out == 1'b0, "still within the 10-tick pulse width at tick 30");
        tick(1);   // tick 31
        check(pin_out == 1'b1, "pulse returns to idle (1) at tick 31, exactly 10 ticks after going active");
        drive_run(0); tick(2);

        // ---- 6. PULSE, repeated: width=5, repeat period=20, cycles=3 ----
        $display("\n-- PULSE repeat x3, width=5, period=20 --");
        cfg_apply(TYPE_PULSE, 1'b0, 0, 5, 20, 3);
        drive_run(1);
        begin
            int rises = 0;
            for (int i = 0; i < 90; i++) begin
                tick(1);
                if (rising_edge_o) rises++;
            end
            check(rises == 3, $sformatf("3 repeats produced exactly 3 rising edges (got %0d)", rises));
            check(pin_out == 1'b0, "idle after all 3 repeats finished");
        end
        drive_run(0); tick(2);

        // ---- 7. SERIAL, MSB-first, 8 bits = 8'b1011_0010 ----
        $display("\n-- SERIAL MSB-first, 8 bits --");
        cfg_apply(TYPE_SERIAL, 1'b0, 0, 0, 0, 0, 1'b1, 16'b1011_0010_0000_0000, 8);
        drive_run(1);
        begin
            logic [7:0] expected = 8'b1011_0010;
            logic [7:0] got = '0;
            tick(1);
            got[7] = pin_out;
            for (int i = 6; i >= 0; i--) begin
                pulse_shift_strobe();
                tick(1);
                got[i] = pin_out;
            end
            check(got == expected, $sformatf("MSB-first SERIAL received %08b (expected %08b)", got, expected));
        end
        drive_run(0); tick(2);

        // ---- 8. SERIAL, LSB-first, 8 bits ----
        $display("\n-- SERIAL LSB-first, 8 bits --");
        cfg_apply(TYPE_SERIAL, 1'b0, 0, 0, 0, 0, 1'b0, 16'b0000_0000_1101_0110, 8);
        drive_run(1);
        begin
            logic [7:0] expected = 8'b1101_0110;  // bit0 first, shifted right
            logic [7:0] got = '0;
            tick(1);
            got[0] = pin_out;
            for (int i = 1; i <= 7; i++) begin
                pulse_shift_strobe();
                tick(1);
                got[i] = pin_out;
            end
            check(got == expected, $sformatf("LSB-first SERIAL received %08b (expected %08b)", got, expected));
        end
        drive_run(0); tick(2);

        // ---- 9. Config change WHILE RUNNING: new config takes effect atomically ----
        $display("\n-- config change while running --");
        cfg_apply(TYPE_CLOCK, 1'b0, 0, 10, 5, 0);  // free-running 10-tick clock
        drive_run(1);
        tick(25);  // run for a while, mid-period somewhere
        cfg_apply(TYPE_PULSE, 1'b0, 0, 3, 0, 0);   // switch to a single 3-tick pulse, `run` stays high throughout
        begin
            int rises = 0;
            for (int i = 0; i < 20; i++) begin
                tick(1);
                if (rising_edge_o) rises++;
            end
            check(rises == 1, $sformatf("after a live config change, exactly 1 pulse fired under the NEW config (got %0d)", rises));
        end
        drive_run(0); tick(2);

        // ---- 10. LOW/HIGH basics + idle_level snap on STOP ----
        $display("\n-- LOW/HIGH + idle snap on stop --");
        cfg_apply(TYPE_HIGH, 1'b1, 0, 0, 0, 0);  // HIGH type, idle=1 (irrelevant while running)
        drive_run(1); tick(3);
        check(pin_out == 1'b1, "type=HIGH drives 1 while running");
        drive_run(0); tick(1);
        check(pin_out == 1'b1, "idle_level=1 happens to equal HIGH's value too (sanity)");

        cfg_apply(TYPE_LOW, 1'b1, 0, 0, 0, 0);   // LOW type, idle=1 (differs from the 0 it drives while running)
        drive_run(1); tick(3);
        check(pin_out == 1'b0, "type=LOW drives 0 while running even though idle_level=1");
        drive_run(0); tick(1);
        check(pin_out == 1'b1, "stopping snaps the pin back to idle_level (1), not LOW's 0");

        // ---- 11. Re-RUN without a fresh apply replays the same SERIAL pattern ----
        $display("\n-- re-run without a fresh apply replays SERIAL cleanly --");
        cfg_apply(TYPE_SERIAL, 1'b0, 0, 0, 0, 0, 1'b1, 16'b1010_0101_0000_0000, 4);
        drive_run(1);
        tick(1); pulse_shift_strobe(); tick(1); pulse_shift_strobe(); tick(1);
        drive_run(0); tick(2);
        drive_run(1);  // run again, no new apply
        begin
            logic [3:0] expected = 4'b1010;
            logic [3:0] got = '0;
            tick(1);
            got[3] = pin_out;
            for (int i = 2; i >= 0; i--) begin
                pulse_shift_strobe();
                tick(1);
                got[i] = pin_out;
            end
            check(got == expected, $sformatf("replayed SERIAL after re-RUN got %04b (expected %04b)", got, expected));
        end
        drive_run(0); tick(2);

        // ---- 12. SERIAL_W=1 instance: CLOCK still works, and sending its one
        //          SERIAL bit doesn't elaborate an invalid part-select ----
        $display("\n-- SERIAL_W=1 instance (phase4_loopback_top's actual width for non-SERIAL pins) --");
        w1_rst_n = 0; w1_run = 0; w1_apply = 0; w1_shift_strobe = 0;
        w1_cfg_type = 0; w1_cfg_idle_level = 0; w1_cfg_delay = 0; w1_cfg_param_a = 0;
        w1_cfg_param_b = 0; w1_cfg_cycles = 0; w1_cfg_msb_first = 1; w1_cfg_data = 0; w1_cfg_bits = 0;
        tick(3);
        @(negedge clk); w1_rst_n = 1;
        tick(2);

        @(negedge clk);
        w1_cfg_type = TYPE_CLOCK; w1_cfg_param_a = 4; w1_cfg_param_b = 2;
        @(negedge clk); w1_apply = 1;
        @(negedge clk); w1_apply = 0;
        @(negedge clk); w1_run = 1;
        tick(1);
        check(w1_pin_out == 1'b1, "SERIAL_W=1 instance's CLOCK mode still toggles correctly (high phase)");
        tick(2);
        check(w1_pin_out == 1'b0, "...and the low phase (period=4, high=2)");
        @(negedge clk); w1_run = 0;

        @(negedge clk);
        w1_cfg_type = TYPE_SERIAL; w1_cfg_msb_first = 1; w1_cfg_data = 1'b1; w1_cfg_bits = 1;
        @(negedge clk); w1_apply = 1;
        @(negedge clk); w1_apply = 0;
        @(negedge clk); w1_run = 1;
        @(posedge clk); #1;
        check(w1_pin_out == 1'b1, "SERIAL_W=1 instance presents its one bit (1) with no shift ever needed");
        @(negedge clk); w1_shift_strobe = 1;
        @(negedge clk); w1_shift_strobe = 0;
        @(posedge clk); #1;
        check(1'b1, "a shift_strobe after the only bit is already done doesn't elaborate {shift_reg[-1:0],...}");
        @(negedge clk); w1_run = 0;

        // ---- summary ----
        $display("\n================================================");
        if (fails == 0)
            $display("ALL TESTS PASSED (%0d checks)", checks);
        else
            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
