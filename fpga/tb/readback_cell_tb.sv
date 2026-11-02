`timescale 1ns / 1ps
//==========================================================================
// readback_cell_tb
//
// Self-checking testbench for fpga/src/readback_cell.sv (Step 2 pad readback).
// The pin (sync_in) and the window (run) are driven on the falling clock
// edge, so the cell sees each value for exactly one rising edge = one tick.
//
// Pass: every check prints PASS and the last line is "ALL TESTS PASSED".
// On the board (EXP-10) the same numbers come back over the link for each of
// chip_top's 22 outputs.
//==========================================================================
module readback_cell_tb;
    logic clk = 0, rst_n = 0, run = 0, pin = 0;
    always #5 clk = ~clk;

    wire [31:0] edges, period, high;
    wire saw0, saw1, end_level;
    readback_cell #(.TICK_W(32)) dut (.clk(clk), .rst_n(rst_n), .run(run), .sync_in(pin),
        .edges(edges), .period(period), .high(high), .saw0(saw0), .saw1(saw1), .end_level(end_level));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    // one tick: set the pin (and window) on the falling edge, let one rising edge take it
    task automatic tick(input logic p, input logic w = 1'b1);
        @(negedge clk); pin = p; run = w;
    endtask
    task automatic ticks(input int n, input logic p, input logic w = 1'b1);
        repeat (n) tick(p, w);
    endtask
    task automatic close_window();       // a few ticks outside the window, pin unchanged
        @(negedge clk); run = 0;
        repeat (3) @(negedge clk);
    endtask
    task automatic expect_all(input int e, input int per, input int hi, input logic s0, input logic s1,
                              input logic el, input string what);
        check(edges == e && period == per && high == hi && saw0 == s0 && saw1 == s1 && end_level == el,
              $sformatf("%s: edges %0d period %0d high %0d saw0 %0d saw1 %0d end %0d (want %0d %0d %0d %0d %0d %0d)",
                        what, edges, period, high, saw0, saw1, end_level, e, per, hi, s0, s1, el));
    endtask

    initial begin
        $display("== readback_cell_tb ==");
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        expect_all(0, 0, 0, 0, 0, 0, "1. after reset everything is 0");

        // 2. a clock: period 10 ticks, high 4, 5 rising edges inside the window
        ticks(3, 1'b0, 1'b0);                         // low before the window
        tick(1'b0);                                   // window opens, pin low
        for (int c = 0; c < 5; c++) begin
            ticks(4, 1'b1); ticks(6, 1'b0);
        end
        close_window();
        expect_all(5, 10, 4, 1, 1, 0, "2. clock 5 x (4 high / 6 low)");

        // 3. results are held after the window, whatever the pin does
        ticks(7, 1'b1, 1'b0); ticks(5, 1'b0, 1'b0); ticks(2, 1'b1, 1'b0);
        expect_all(5, 10, 4, 1, 1, 0, "3. held after the run (pin toggled outside the window)");

        // 4. a new window clears everything: pin held HIGH the whole time
        ticks(2, 1'b1, 1'b0);                         // already high before the window
        ticks(20, 1'b1);
        close_window();
        expect_all(0, 0, 0, 0, 1, 1, "4. static HIGH: no edge, saw1 only, ends high");

        // 5. static LOW
        ticks(2, 1'b0, 1'b0);
        ticks(20, 1'b0);
        close_window();
        expect_all(0, 0, 0, 1, 0, 0, "5. static LOW: saw0 only, ends low");

        // 6. a rise on the very first window tick counts (compared with the level before)
        ticks(2, 1'b0, 1'b0);
        tick(1'b1);                                   // window opens with the pin rising
        ticks(9, 1'b1);
        close_window();
        expect_all(1, 0, 0, 0, 1, 1, "6. rise on the first window tick: 1 edge");

        // 7. one high pulse of 7 ticks: edges 1, high 7, no period
        ticks(2, 1'b0, 1'b0);
        ticks(5, 1'b0); ticks(7, 1'b1); ticks(5, 1'b0);
        close_window();
        expect_all(1, 0, 7, 1, 1, 0, "7. single 7-tick pulse");

        // 8. an active-low pulse while high: the fall has no rise before it in the window, so
        //    high stays 0; the rise after it is 1 edge
        ticks(2, 1'b1, 1'b0);
        ticks(4, 1'b1); ticks(3, 1'b0); ticks(4, 1'b1);
        close_window();
        expect_all(1, 0, 0, 1, 1, 1, "8. active-low pulse: 1 edge (its end), no high time");

        // 9. the last period counts: 3 periods of 8 then 2 of 12 (high 6)
        ticks(2, 1'b0, 1'b0);
        tick(1'b0);
        for (int c = 0; c < 3; c++) begin ticks(4, 1'b1); ticks(4, 1'b0); end
        for (int c = 0; c < 2; c++) begin ticks(6, 1'b1); ticks(6, 1'b0); end
        close_window();
        expect_all(5, 12, 6, 1, 1, 0, "9. period / high are the last ones measured");

        // 10. reset in the middle clears it all
        tick(1'b1); ticks(3, 1'b0);
        run = 0; rst_n = 0; @(negedge clk); rst_n = 1; @(negedge clk);   // window closed, then reset
        expect_all(0, 0, 0, 0, 0, 0, "10. async reset clears the results");

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $finish;
    end
endmodule
