`timescale 1ns / 1ps
//==========================================================================
// seq_bank_tb -- Phase 7 round 2: table RAM + next-step bank.
// Every table byte is written as f(step, offset) = step*16 + offset*7 (mod
// 256), so any mixed-up step, word or lane shows up as a wrong byte.
//==========================================================================
module seq_bank_tb;

    localparam int STEP_W = 4, EB = 256, USED = 148, HB = 12;
    localparam int NW = (USED + 3) / 4;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    int unsigned cyc = 0;
    always @(posedge clk) cyc++;

    logic wr_en = 0;
    logic [STEP_W+7:0] wr_addr = '0;
    logic [7:0] wr_data = '0;
    logic [STEP_W-1:0] fetch_step = '0;
    logic fetch_ready, apply_tick = 0;
    logic [USED*8-1:0] next_entry;
    logic [HB*8-1:0] hdr;

    seq_bank #(.STEP_W(STEP_W), .ENTRY_BYTES(EB), .USED_BYTES(USED), .HDR_BYTES(HB)) dut (
        .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .fetch_step(fetch_step), .fetch_ready(fetch_ready), .apply_tick(apply_tick),
        .next_entry(next_entry), .hdr(hdr));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask
    task automatic tick(input int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    function automatic logic [7:0] f(input int s, input int o, input int salt);
        return 8'((s * 16 + o * 7 + salt) & 8'hFF);
    endfunction

    task automatic write_step(input int s, input int salt);
        for (int o = 0; o < USED; o++) begin
            wr_en = 1; wr_addr = (s * EB + o); wr_data = f(s, o, salt); tick(1);
        end
        wr_en = 0;
    endtask

    function automatic int bank_errors(input int s, input int salt);
        int e = 0;
        for (int o = 0; o < USED; o++) if (next_entry[o*8 +: 8] !== f(s, o, salt)) e++;
        return e;
    endfunction

    task automatic wait_ready(output int waited);
        waited = 0;
        while (!fetch_ready && waited < 1000) begin tick(1); waited++; end
    endtask

    initial begin
        int w, t0;
        tick(2); rst_n = 1; tick(2);
        for (int s = 0; s < 16; s++) write_step(s, 0);

        $display("\n-- fetch step 0 after the table write --");
        wait_ready(w);
        check(fetch_ready && bank_errors(0, 0) == 0, $sformatf("step 0 fetched, all %0d bytes right", USED));

        $display("\n-- fetch step 9: copy time --");
        fetch_step = 9; t0 = cyc;
        tick(1);
        check(!fetch_ready, "ready drops as soon as another step is asked for");
        wait_ready(w);
        check(fetch_ready && bank_errors(9, 0) == 0, "step 9 fetched, all bytes right");
        check(cyc - t0 <= NW + 3, $sformatf("copy took %0d ticks (<= %0d words + 3)", cyc - t0, NW));

        $display("\n-- change the step mid-copy --");
        fetch_step = 4; tick(10);
        fetch_step = 13;
        wait_ready(w);
        check(fetch_ready && bank_errors(13, 0) == 0, "ends up holding step 13 (the last one asked for), all bytes right");

        $display("\n-- rewriting the table invalidates the bank --");
        write_step(13, 5);
        tick(1);
        check(!fetch_ready || bank_errors(13, 5) == 0, "not ready on stale data after a write");
        wait_ready(w);
        check(fetch_ready && bank_errors(13, 5) == 0, "re-copied step 13 with the new bytes");

        $display("\n-- header: next bank on an apply tick, held copy afterwards --");
        apply_tick = 1;
        #1;
        check(hdr == next_entry[HB*8-1:0], "apply tick: hdr = next bank's header");
        tick(1); apply_tick = 0;
        fetch_step = 2;            // bank starts refilling with another step
        tick(5);
        check(hdr == {f(13,11,5), f(13,10,5), f(13,9,5), f(13,8,5), f(13,7,5), f(13,6,5),
                      f(13,5,5), f(13,4,5), f(13,3,5), f(13,2,5), f(13,1,5), f(13,0,5)},
              "after the apply tick hdr keeps step 13's header while the bank refills");
        wait_ready(w);
        check(bank_errors(2, 0) == 0, "and the bank then holds step 2");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
