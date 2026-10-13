`timescale 1ns / 1ps
//==========================================================================
// phase4_loopback_top_tb
//
// Pre-validates phase4_loopback_top.sv before it ever touches Vivado (no
// Vivado/license available in this environment -- see docs/experiments/
// EXP-05 and WORKLOG for what still needs to happen on real hardware).
//
// Models the 5 EXTERNAL jumper wires that only exist physically on the real
// board (J3-i <-> J2/J3-(i+16)) by directly shorting fmc_pins[i] to
// fmc_pins[i+16] here -- the DUT itself never connects them; that's exactly
// what the real jumpers are for.
//
// Test clock/pulse/serial timings in config/phase4_loopback_test.yaml are
// deliberately human/multimeter-scale (100 Hz, 500 ms, 10 Hz), i.e. far too
// slow to simulate to completion in reasonable wall-clock time (500 ms =
// 50,000,000 ticks). This testbench checks what's reachable in a short
// simulated window -- first edges, immediate levels, the LED mux, the
// fault latch staying clear under a correctly-looped-back signal -- not
// full-duration waveforms. That's a deliberate, documented scope limit, not
// a shortcut hiding a gap: the brief's own real validation is the hardware
// multimeter/scope step this testbench cannot replace.
//==========================================================================
module phase4_loopback_top_tb;

    logic       clk = 0;
    logic [4:0] sw;
    logic [7:0] led;
    wire  [31:0] fmc_pins;

    phase4_loopback_top dut (
        .clk(clk), .sw(sw), .led(led), .fmc_pins(fmc_pins)
    );

    // the 5 external jumper wires
    genvar g;
    generate
        for (g = 0; g < 5; g = g + 1) begin : g_jumper
            assign fmc_pins[g + 16] = fmc_pins[g];
        end
    endgenerate

    always #5 clk = ~clk;

    int fails = 0, checks = 0;
    task automatic check(logic cond, string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    task automatic tick(int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    task automatic select_pair(int idx);
        sw[2:0] = idx[2:0];
        tick(2);
    endtask

    initial begin
        sw = 5'b00000;  // RUN=0, sel=0
        tick(20);       // let the power-on reset + auto-apply settle

        check(led[4] == 1'b0, "RUN LED off before sw[4] is raised");

        sw[4] = 1'b1;   // RUN
        tick(5);

        // ---- test_clock (pair 0): should be high immediately (delay=0) ----
        $display("\n-- test_clock (pair 0) --");
        select_pair(0);
        check(led[0] == 1'b1, "clock pin high right after RUN (delay=0, starts in its high phase)");
        tick(500_000);  // 5 ms: well past the 2-cycle sync, before the first falling edge (period=10ms)
        check(led[1] == led[0], "captured level matches the driven level (through the jumper + 2-FF sync)");
        check(led[3] == 1'b0, "no fault latched for the correctly-looped-back clock pin");

        tick(600_000);  // past the 10 ms period's falling edge (~5ms high + 5ms low)
        $display("  (clock pin now: driven=%b captured=%b, mid-waveform)", led[0], led[1]);
        check(led[3] == 1'b0, "still no fault after a full period has elapsed");

        // ---- test_pulse (pair 1): active-high, delay=0, width=500 ms --
        //      far too long to finish in this testbench; just confirm it
        //      rose and is holding, and the loopback isn't faulting.
        $display("\n-- test_pulse (pair 1) --");
        select_pair(1);
        tick(10);
        check(led[0] == 1'b1, "pulse pin went high immediately (delay=0)");
        tick(1_000_000);  // 10 ms -- a small fraction of the 500 ms width
        check(led[0] == 1'b1, "pulse pin still high 10 ms in (width=500 ms, nowhere near done)");
        check(led[1] == 1'b1, "captured side sees it too, through the jumper + 2-FF sync");
        check(led[3] == 1'b0, "no fault latched for the correctly-looped-back pulse pin");

        // ---- test_serial (pair 2): data=0xA5=1010_0101, MSB-first --
        //      first bit (1) is presented immediately, no shift needed yet
        //      (strobe period=100 ms, far too slow to see a shift here).
        $display("\n-- test_serial (pair 2) --");
        select_pair(2);
        tick(10);
        check(led[0] == 1'b1, "first SERIAL bit (MSB of 0xA5 = 1) presented immediately, no strobe needed");

        // ---- test_low (pair 3) ----
        $display("\n-- test_low (pair 3) --");
        select_pair(3);
        tick(10);
        check(led[0] == 1'b0, "LOW pin drives 0");
        check(led[1] == 1'b0, "captured side reads 0 through the jumper");
        check(led[2] == 1'b1, "live match asserted for LOW");
        check(led[3] == 1'b0, "no fault latched for LOW");

        // ---- test_high (pair 4) ----
        $display("\n-- test_high (pair 4) --");
        select_pair(4);
        tick(10);
        check(led[0] == 1'b1, "HIGH pin drives 1");
        check(led[1] == 1'b1, "captured side reads 1 through the jumper");
        check(led[2] == 1'b1, "live match asserted for HIGH");
        check(led[3] == 1'b0, "no fault latched for HIGH");

        // ---- out-of-range sw[3:0] falls back to pair 0 ----
        $display("\n-- sw[3:0] >= 5 falls back to pair 0 --");
        sw[3:0] = 4'd9;
        tick(2);
        check(led[0] == 1'b1, "sw[3:0]=9 (out of the 0-4 range) shows pair 0's (clock, currently high) status");

        // ---- lowering sw[4] clears RUN and the fault-latch settle state ----
        $display("\n-- sw[4] low stops RUN --");
        sw[3:0] = 0;
        sw[4] = 1'b0;
        tick(5);
        check(led[4] == 1'b0, "RUN LED drops when sw[4] goes low");
        check(led[0] == 1'b0, "test_clock pin returns to its idle level (0) on STOP");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
