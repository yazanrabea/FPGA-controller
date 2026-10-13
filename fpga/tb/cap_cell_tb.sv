`timescale 1ns / 1ps
//==========================================================================
// cap_cell_tb — self-checking testbench for cap_cell.sv (Phase 3).
// Same conventions as sig_cell_tb.sv: drive stimulus at @(negedge clk),
// read/wait only at @(posedge clk) + a 1ns settle (see tick()'s comment in
// sig_cell_tb.sv for why that settle matters).
//==========================================================================
module cap_cell_tb;

    localparam int TICK_W = 32;
    localparam int CAP_W  = 16;

    logic              clk = 0;
    logic              rst_n;
    logic              run;
    logic              apply;
    logic              sync_in;
    logic [1:0]        cfg_mode;
    logic              cfg_msb_first;
    logic [TICK_W-1:0] cfg_bits;
    logic              capture_strobe;

    logic                level_out;
    logic [TICK_W-1:0]   edge_count;
    logic [TICK_W-1:0]   period_ticks;
    logic [TICK_W-1:0]   high_ticks;
    logic                period_valid;
    logic [CAP_W-1:0]    capture_reg;
    logic                done_o;

    localparam logic [1:0] MODE_LEVEL      = 2'd0;
    localparam logic [1:0] MODE_EDGE_COUNT = 2'd1;
    localparam logic [1:0] MODE_PERIOD     = 2'd2;
    localparam logic [1:0] MODE_SERIAL     = 2'd3;

    cap_cell #(.TICK_W(TICK_W), .CAP_W(CAP_W)) dut (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .sync_in(sync_in),
        .cfg_mode(cfg_mode), .cfg_msb_first(cfg_msb_first), .cfg_bits(cfg_bits),
        .capture_strobe(capture_strobe),
        .level_out(level_out), .edge_count(edge_count),
        .period_ticks(period_ticks), .high_ticks(high_ticks), .period_valid(period_valid),
        .capture_reg(capture_reg), .done(done_o)
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

    task automatic drive_run(logic val);
        @(negedge clk);
        run = val;
    endtask

    task automatic drive_sync(logic val);
        @(negedge clk);
        sync_in = val;
    endtask

    task automatic cfg_apply(logic [1:0] mode, logic msb = 1'b1, int bits = 0);
        @(negedge clk);
        cfg_mode      = mode;
        cfg_msb_first = msb;
        cfg_bits      = bits;
        @(negedge clk);
        apply = 1;
        @(negedge clk);
        apply = 0;
    endtask

    task automatic pulse_capture_strobe();
        @(negedge clk);
        capture_strobe = 1;
        @(negedge clk);
        capture_strobe = 0;
    endtask

    task automatic reset_dut();
        rst_n = 0; run = 0; apply = 0; sync_in = 0;
        cfg_mode = 0; cfg_msb_first = 1; cfg_bits = 0; capture_strobe = 0;
        tick(3);
        @(negedge clk); rst_n = 1;
        tick(2);
    endtask

    // -----------------------------------------------------------------
    initial begin
        reset_dut();

        // ---- 1. LEVEL: mirrors sync_in with 1-cycle latency ----
        $display("\n-- LEVEL --");
        cfg_apply(MODE_LEVEL);
        drive_run(1);
        drive_sync(1); tick(1);
        check(level_out == 1'b1, "level_out follows sync_in=1");
        drive_sync(0); tick(1);
        check(level_out == 1'b0, "level_out follows sync_in=0");
        drive_run(0); tick(2);

        // ---- 2. EDGE_COUNT: count a known number of rising edges ----
        $display("\n-- EDGE_COUNT --");
        cfg_apply(MODE_EDGE_COUNT);
        drive_run(1);
        begin
            int n_edges = 7;
            for (int i = 0; i < n_edges; i++) begin
                drive_sync(1); tick(2);
                drive_sync(0); tick(2);
            end
            check(edge_count == n_edges, $sformatf("counted %0d rising edges (expected %0d)", edge_count, n_edges));
        end
        drive_run(0); tick(1);
        check(edge_count == 0, "edge_count resets to 0 once run drops");
        tick(1);

        // ---- 3. PERIOD: measure a known period/duty from a hand-driven waveform ----
        $display("\n-- PERIOD --");
        cfg_apply(MODE_PERIOD);
        drive_run(1);
        begin
            // period = 20 ticks, high = 7 ticks, repeated 3 times
            logic got_valid_on_2nd_edge = 0;
            int valids = 0;
            drive_sync(1);
            fork
                begin
                    for (int i = 0; i < 3; i++) begin
                        tick(7);  drive_sync(0);
                        tick(13); drive_sync(1);
                    end
                end
                begin
                    for (int i = 0; i < 60; i++) begin
                        tick(1);
                        if (period_valid) begin
                            valids++;
                            check(period_ticks == 20, $sformatf("measured period = 20 (got %0d)", period_ticks));
                            check(high_ticks == 7, $sformatf("measured high time = 7 (got %0d)", high_ticks));
                        end
                    end
                end
            join
            check(valids == 2, $sformatf("period_valid pulsed exactly twice for 3 edges seen (got %0d)", valids));
        end
        drive_run(0); tick(2);

        // ---- 4. SERIAL capture, MSB-first, 8 bits = 8'b1011_0010 ----
        $display("\n-- SERIAL capture MSB-first, 8 bits --");
        cfg_apply(MODE_SERIAL, 1'b1, 8);
        drive_run(1);
        begin
            logic [7:0] pattern = 8'b1011_0010;
            for (int i = 7; i >= 0; i--) begin
                drive_sync(pattern[i]);
                pulse_capture_strobe();
                tick(1);
            end
            check(capture_reg[7:0] == pattern, $sformatf("captured %08b (expected %08b)", capture_reg[7:0], pattern));
            check(done_o == 1'b0, "done is a 1-cycle pulse, already past it by the time we sample here");
        end
        drive_run(0); tick(2);

        // ---- 5. SERIAL capture, LSB-first, 8 bits into a 16-bit register ----
        // lsb_first shifts right (new bit enters at the top), so a partial capture
        // (8 bits into CAP_W=16) lands at the TOP [15:8], not [7:0] -- see cap_cell.sv's
        // header comment. Reading the full register and checking the top byte here.
        $display("\n-- SERIAL capture LSB-first, 8 bits --");
        cfg_apply(MODE_SERIAL, 1'b0, 8);
        drive_run(1);
        begin
            logic [7:0] pattern = 8'b1101_0110;  // bit0 (LSB) sent first
            for (int i = 0; i <= 7; i++) begin
                drive_sync(pattern[i]);
                pulse_capture_strobe();
                tick(1);
            end
            check(capture_reg[15:8] == pattern, $sformatf("captured %08b (expected %08b)", capture_reg[15:8], pattern));
        end
        drive_run(0); tick(2);

        // ---- 6. apply while running restarts cleanly (EDGE_COUNT -> SERIAL) ----
        $display("\n-- apply while running restarts cleanly --");
        cfg_apply(MODE_EDGE_COUNT);
        drive_run(1);
        drive_sync(1); tick(2); drive_sync(0); tick(2);
        drive_sync(1); tick(2); drive_sync(0); tick(2);  // 2 edges counted so far
        cfg_apply(MODE_SERIAL, 1'b1, 4);                  // switch mode mid-run
        begin
            logic [3:0] pattern = 4'b1100;
            for (int i = 3; i >= 0; i--) begin
                drive_sync(pattern[i]);
                pulse_capture_strobe();
                tick(1);
            end
            check(capture_reg[3:0] == pattern, $sformatf("captured %04b after a live mode switch (expected %04b)", capture_reg[3:0], pattern));
        end
        drive_run(0); tick(2);

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
