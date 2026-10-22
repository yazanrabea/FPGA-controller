`timescale 1ns / 1ps
//==========================================================================
// jtag_echo_core_tb
//
// Self-checking testbench for jtag_echo_core (JTAG link step J1). Models
// what BSCANE2 does for a USER1 DR scan, one TCK rising edge per TAP state:
// Capture-DR (1 edge), Shift-DR (N edges, TDI LSB first, TDO read before
// each edge as the TAP does on the falling edge), Exit1/Update-DR (Update
// is registered on the edge leaving Update-DR), then Run-Test/Idle.
//
// Pass: scan k returns ~(data of scan k-1); the first scan returns all
// ones (~0 after configuration); n_updates counts scans; SEL low = ignored.
// On the board, the same check is scripts/jtag_echo_test.tcl (EXP-05).
//==========================================================================
module jtag_echo_core_tb;
    localparam int N = 64;   // small DR for the testbench; the top uses 1024

    logic tck = 0, sel = 0, capture = 0, shift = 0, update = 0, tdi = 0;
    wire  tdo;
    wire  [N-1:0] last;
    wire  [15:0]  n_updates;

    jtag_echo_core #(.DR_BITS(N)) dut (
        .tck(tck), .sel(sel), .capture(capture), .shift(shift), .update(update),
        .tdi(tdi), .tdo(tdo), .last(last), .n_updates(n_updates));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    task automatic tck_edge();
        #10 tck = 1; #10 tck = 0;
    endtask

    // one full DR scan: send `din`, return what came out on TDO
    task automatic dr_scan(input logic [N-1:0] din, output logic [N-1:0] dout, input logic use_sel = 1);
        sel = use_sel;
        capture = 1; tck_edge(); capture = 0;            // Capture-DR
        shift = 1;
        for (int i = 0; i < N; i++) begin
            tdi = din[i];
            dout[i] = tdo;                                // TAP samples TDO on the falling edge
            tck_edge();
        end
        shift = 0;
        tck_edge();                                       // Exit1-DR
        update = 1; tck_edge(); update = 0;              // Update-DR -> Run-Test/Idle
        tck_edge();                                       // Run-Test/Idle
        sel = 0;
    endtask

    logic [N-1:0] a = 64'hDEAD_BEEF_0123_4567, b = 64'hA5A5_5A5A_FFFF_0000, got;

    initial begin
        $display("== jtag_echo_core_tb (DR_BITS=%0d) ==", N);
        dr_scan(a, got);
        check(got == {N{1'b1}}, "first scan returns ~0 (all ones)");
        check(last == a, "last = the data just shifted in");
        check(n_updates == 1, "n_updates = 1");

        dr_scan(b, got);
        check(got == ~a, "second scan returns ~(first scan's data)");
        check(last == b, "last = second scan's data");

        dr_scan('0, got);
        check(got == ~b, "third scan returns ~(second scan's data)");
        check(n_updates == 3, "n_updates = 3");

        dr_scan(a, got, 1'b0);                            // another instruction in the IR
        check(last == '0 && n_updates == 3, "SEL low: scan ignored, nothing updated");

        dr_scan(b, got);
        check(got == {N{1'b1}}, "after an ignored scan: still ~(last real scan = 0)");

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $finish;
    end
endmodule
