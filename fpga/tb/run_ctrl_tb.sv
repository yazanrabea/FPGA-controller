`timescale 1ns / 1ps
//==========================================================================
// run_ctrl_tb — self-checking testbench for run_ctrl.sv (Phase 3).
// Same conventions as sig_cell_tb.sv/cap_cell_tb.sv: drive stimulus at
// @(negedge clk), read/wait only at @(posedge clk) + a 1ns settle.
//==========================================================================
module run_ctrl_tb;

    logic clk = 0;
    logic rst_n;
    logic run_set, run_clear, apply_cmd;
    logic run, apply;

    run_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd),
        .run(run), .apply(apply)
    );

    always #5 clk = ~clk;

    int fails = 0;
    int checks = 0;

    task automatic check(logic cond, string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin
            $display("  FAIL: %s", msg);
            fails++;
        end
    endtask

    task automatic tick(int n = 1);
        repeat (n) begin
            @(posedge clk);
            #1;
        end
    endtask

    // Icarus doesn't support `ref` task ports, so one pulse task per signal
    // instead of a single generic one.
    task automatic pulse_run_set();
        @(negedge clk); run_set = 1;
        @(negedge clk); run_set = 0;
    endtask
    task automatic pulse_run_clear();
        @(negedge clk); run_clear = 1;
        @(negedge clk); run_clear = 0;
    endtask
    task automatic pulse_apply_cmd();
        @(negedge clk); apply_cmd = 1;
        @(negedge clk); apply_cmd = 0;
    endtask

    initial begin
        rst_n = 0; run_set = 0; run_clear = 0; apply_cmd = 0;
        tick(3);
        @(negedge clk); rst_n = 1;
        tick(2);

        // ---- 1. reset state ----
        $display("\n-- reset state --");
        check(run == 1'b0, "run is 0 after reset");
        check(apply == 1'b0, "apply is 0 after reset");

        // ---- 2. run_set (one-shot pulse) raises run, exactly once ----
        $display("\n-- run_set pulse --");
        pulse_run_set();
        tick(5);  // 2-FF sync + edge detect: a few cycles of latency expected
        check(run == 1'b1, "run went high after a run_set pulse");

        // ---- 3. run_clear lowers run ----
        $display("\n-- run_clear pulse --");
        pulse_run_clear();
        tick(5);
        check(run == 1'b0, "run went low after a run_clear pulse");

        // ---- 4. run_set HELD HIGH for many cycles (like a switch, not a one-shot) ----
        //         must still only register as a single rising edge.
        $display("\n-- run_set held high like a switch --");
        @(negedge clk); run_set = 1;
        tick(20);
        check(run == 1'b1, "run went high while run_set is held");
        @(negedge clk); run_set = 0;
        tick(3);
        check(run == 1'b1, "run stays high after releasing run_set (no re-trigger needed)");
        pulse_run_clear();
        tick(5);

        // ---- 5. apply_cmd held high for many cycles fires exactly ONE apply pulse ----
        $display("\n-- apply_cmd held high produces exactly one apply pulse --");
        begin
            int applies = 0;
            @(negedge clk); apply_cmd = 1;
            for (int i = 0; i < 30; i++) begin
                tick(1);
                if (apply) applies++;
            end
            check(applies == 1, $sformatf("apply_cmd held for 30 cycles produced exactly 1 apply pulse (got %0d)", applies));
            @(negedge clk); apply_cmd = 0;
            tick(3);
        end

        // ---- 6. releasing then re-asserting apply_cmd fires again ----
        $display("\n-- apply_cmd re-arms after release --");
        begin
            int applies = 0;
            pulse_apply_cmd();
            for (int i = 0; i < 10; i++) begin
                tick(1);
                if (apply) applies++;
            end
            check(applies == 1, $sformatf("a second apply_cmd pulse fired apply again exactly once (got %0d)", applies));
        end

        // ---- 7. simultaneous run_set and run_clear: STOP wins ----
        $display("\n-- simultaneous set+clear: clear wins --");
        @(negedge clk); run_set = 1; run_clear = 1;
        tick(5);
        check(run == 1'b0, "run_clear takes priority over a simultaneous run_set");
        @(negedge clk); run_set = 0; run_clear = 0;
        tick(3);

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
