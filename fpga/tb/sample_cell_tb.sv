`timescale 1ns / 1ps
//==========================================================================
// sample_cell_tb: self-checking testbench for fpga/src/sample_cell.sv
// (verification plan 2026-11-01 Step 3).
//
// The pins carry a free-running 7-bit tick counter (bits 6:0) plus a trigger
// line the testbench drives (bit 7). So every recorded sample says which tick
// it was taken on: consecutive samples must differ by exactly cfg_div (mod
// 128), and the trigger sample must be the first one with the expected
// trigger condition.
//
// DEPTH = 16 so the ring wraps quickly. Pass = "sample_cell_tb: N/N PASS".
//==========================================================================
module sample_cell_tb;
    localparam int N = 8, DEPTH = 16, AW = 4;

    logic clk = 0, rst_n = 0, run = 0, apply = 0, trig_ext = 0;
    always #5 clk = ~clk;                       // 100 MHz, 10 ns tick

    logic [6:0] cnt = 0;
    logic       tline = 0;
    always @(posedge clk) cnt <= cnt + 1'b1;
    wire [N-1:0] sync_in = {tline, cnt};

    logic [31:0]   cfg_div;
    logic [AW:0]   cfg_n, cfg_pre;
    logic [2:0]    cfg_trig;
    logic [2:0]    cfg_trig_pin;
    logic [AW-1:0] rd_idx = 0;
    logic [N-1:0]  rd_data;
    logic          armed, triggered, done;
    logic [AW:0]   n_valid, trig_idx;
    logic [31:0]   trig_count;

    sample_cell #(.N(N), .DEPTH(DEPTH), .TICK_W(32)) dut (
        .clk, .rst_n, .run, .apply, .sync_in,
        .cfg_div, .cfg_n, .cfg_pre, .cfg_trig, .cfg_trig_pin, .trig_ext,
        .rd_idx, .rd_data, .armed, .triggered, .done, .n_valid, .trig_idx, .trig_count);

    localparam logic [2:0] NOW = 0, EXT = 1, RISE = 2, FALL = 3, HIGH = 4, LOW = 5;

    int pass = 0, total = 0;
    task automatic check(input string what, input bit ok);
        total++;
        if (ok) pass++;
        else $display("FAIL: %s", what);
    endtask

    task automatic tick(input int n);
        repeat (n) @(posedge clk);
        #1;
    endtask

    task automatic configure(input int div, input int n, input int pre, input logic [2:0] trig);
        cfg_div = div; cfg_n = n; cfg_pre = pre; cfg_trig = trig; cfg_trig_pin = 7;
        apply = 1; tick(1); apply = 0;
    endtask

    task automatic start();
        run = 1; tick(1);
    endtask

    task automatic stop();
        run = 0; tick(1);
    endtask

    task automatic wait_done(input int max_ticks);
        int k;
        for (k = 0; k < max_ticks && !done; k++) tick(1);
    endtask

    logic [N-1:0] rec [0:DEPTH-1];
    task automatic read_all();     // rd_data is valid one clock after rd_idx
        int i;
        for (i = 0; i < DEPTH; i++) begin
            rd_idx = i[AW-1:0];
            tick(1);
            rec[i] = rd_data;
        end
    endtask

    // samples 0..n-1 are spaced by `div` ticks (mod 128)
    function automatic bit spaced(input int n, input int div);
        int i;
        spaced = 1;
        for (i = 1; i < n; i++)
            if (rec[i][6:0] != rec[i - 1][6:0] + div[6:0]) spaced = 0;
    endfunction

    int t;
    logic [6:0] first_cnt;

    initial begin
        cfg_div = 1; cfg_n = 1; cfg_pre = 0; cfg_trig = NOW; cfg_trig_pin = 7;
        tick(3); rst_n = 1; tick(2);

        // ---- 1. immediate trigger, every tick ----
        configure(1, 10, 0, NOW);
        check("idle after reset: not armed, not done", !armed && !done && !triggered);
        first_cnt = cnt + 1'b1;                     // the first sample is taken on the tick after run rises
        start();
        wait_done(50);
        check("NOW div 1: done", done && triggered && !armed);
        check("NOW div 1: 10 samples, trigger at 0", n_valid == 10 && trig_idx == 0);
        tick(20);                                   // keeps the record: no writes after done
        read_all();
        check("NOW div 1: the first sample is the tick after run rose", rec[0][6:0] == first_cnt);
        check("NOW div 1: consecutive ticks", spaced(10, 1));
        check("NOW: trig_count 0 (the first sample)", trig_count == 0);

        // ---- 2. rate divider ----
        stop(); configure(3, 8, 0, NOW); start();
        wait_done(100);
        read_all();
        check("NOW div 3: done, 8 samples", done && n_valid == 8);
        check("NOW div 3: samples 3 ticks apart", spaced(8, 3));
        stop(); configure(0, 4, 0, NOW); start();
        wait_done(20); read_all();
        check("div 0 = every tick", done && spaced(4, 1));

        // ---- 3. rising edge with pre-trigger, ring wraps first ----
        stop(); tline = 0; configure(2, 12, 5, RISE);
        first_cnt = cnt + 1'b1; start();
        tick(2 * 40);                               // 40 samples: the 16-deep ring wraps twice
        check("RISE: armed, waiting", armed && !triggered && !done);
        tline = 1;
        wait_done(100);
        read_all();
        check("RISE: done, 12 samples, trigger at index 5", done && n_valid == 12 && trig_idx == 5);
        check("RISE: samples before the trigger have the line low", rec[4][7] == 0 && rec[0][7] == 0);
        check("RISE: the trigger sample is the first with the line high", rec[5][7] == 1);
        check("RISE: after the trigger the line stays high", rec[11][7] == 1);
        check("RISE: one continuous record across the ring wrap", spaced(12, 2));
        // the record's first sample was taken (trig_count - trig_idx) samples after arming:
        // its counter value = first_cnt + that * div
        check("RISE: trig_count places the record in time (>= 40 samples in)",
              trig_count >= 40 && rec[0][6:0] == first_cnt + 7'((trig_count - trig_idx) * 2));

        // a line that is already high is not a rising edge: wait for 1 -> 0 -> 1
        stop(); tline = 1; configure(1, 6, 2, RISE); start();
        tick(10);
        check("RISE with the line already high: no trigger", armed && !triggered);
        tline = 0; tick(5);
        check("RISE: a falling edge is not a trigger", armed && !triggered);
        tline = 1; wait_done(30); read_all();
        check("RISE: triggers on the real 0 -> 1 edge", done && trig_idx == 2 && rec[1][7] == 0 && rec[2][7] == 1);

        // ---- 4. trigger before the pre-trigger part is full ----
        stop(); tline = 0; configure(1, 10, 6, RISE); start();
        tick(2); tline = 1;                         // ~2 samples before the edge
        wait_done(50); read_all();
        check("early trigger: shorter at the front", done && trig_idx < 6 && trig_idx >= 1 && n_valid == trig_idx + 4);
        check("early trigger: rec[trig_idx] is the edge", rec[trig_idx][7] == 1 && rec[trig_idx - 1][7] == 0);
        check("early trigger: continuous", spaced(n_valid, 1));

        // ---- 5. falling edge ----
        stop(); tline = 1; configure(1, 6, 2, FALL); start();
        tick(8); tline = 0;
        wait_done(30); read_all();
        check("FALL: trigger at 2, line 1 then 0", done && trig_idx == 2 && rec[1][7] == 1 && rec[2][7] == 0);
        stop(); tline = 0; configure(1, 6, 2, FALL); start();
        tick(10);
        check("FALL with the line already low: no trigger", armed && !triggered);
        tline = 1; tick(5); tline = 0;
        wait_done(30); read_all();
        check("FALL: triggers on the real 1 -> 0 edge", done && trig_idx == 2 && rec[1][7] == 1 && rec[2][7] == 0);

        // ---- 6. level triggers: HIGH fires at once if the line is already high ----
        stop(); tline = 1; configure(1, 4, 2, HIGH); start();
        wait_done(20); read_all();
        check("HIGH already high: first sample is the trigger", done && trig_idx == 0 && n_valid == 2 && rec[0][7] == 1);
        stop(); tline = 1; configure(1, 4, 1, LOW); start();
        tick(5); check("LOW: waits while high", armed && !triggered);
        tline = 0; wait_done(20); read_all();
        check("LOW: trigger on the first low sample", done && trig_idx == 1 && rec[1][7] == 0 && rec[0][7] == 1);

        // ---- 7. external strobe (e.g. a sequencer step start), remembered until the next sample ----
        stop(); tline = 0; configure(4, 6, 2, EXT); start();
        tick(20); check("EXT: waits for the strobe", armed && !triggered);
        // strobe on the tick right after a sample, so it falls BETWEEN two samples (div 4)
        t = dut.wr_addr;
        while (dut.wr_addr == t) tick(1);
        @(negedge clk); trig_ext = 1; @(negedge clk); trig_ext = 0;
        wait_done(60); read_all();
        check("EXT: triggered by the strobe, 6 samples", done && n_valid == 6 && trig_idx == 2);
        check("EXT: continuous at div 4", spaced(6, 4));

        // ---- 8. run falls mid-record: stop and keep; re-arm clears ----
        stop(); tline = 0; configure(1, 16, 0, NOW); start();
        tick(5); stop();
        t = n_valid;
        check("stopped mid-record: not done, data kept", !done && triggered && t >= 4 && t <= 6);
        tick(10);
        check("stopped: nothing more written", n_valid == t);
        read_all();
        check("stopped: kept samples are continuous", spaced(t, 1));
        start();
        check("re-arm clears the record", n_valid == 0 && !triggered && armed);
        wait_done(40);

        // ---- 9. apply during a run doesn't erase the record ----
        stop(); configure(1, 16, 0, NOW); start();
        tick(6); t = n_valid;
        configure(2, 4, 0, NOW);
        check("mid-run apply keeps recording", n_valid >= t && !done);
        wait_done(40);
        check("record completes with the config it was armed with", done && n_valid == 16);

        // ---- 10. clamps: n = 0 -> 1, n > DEPTH -> DEPTH ----
        stop(); configure(1, 0, 0, NOW); start(); wait_done(10);
        check("n = 0 records 1 sample", done && n_valid == 1);
        stop(); configure(1, 31, 0, NOW); start(); wait_done(60);
        check("n > DEPTH records DEPTH", done && n_valid == DEPTH);

        $display("sample_cell_tb: %0d/%0d %s", pass, total, pass == total ? "PASS" : "FAIL");
        $finish;
    end
endmodule
