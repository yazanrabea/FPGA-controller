`timescale 1ns / 1ps
//==========================================================================
// jtag_link_bridge_tb
//
// Self-checking testbench for jtag_link_bridge (JTAG link step J2). A model
// of the PC (the J4 transport's rules) does full-length USER scans the way
// BSCANE2 presents them (preamble TCK edges with SEL low = the IR scan and
// state moves, then Capture / Shift x DR_BITS / Update / Idle).
//
// Two bridges on one TAP, told apart by SEL (like two USER chains):
//   A: RX_GAP 32, its system side loops every down byte back up as byte+1.
//   B: RX_GAP huge, nothing drains its down FIFO: credit / overflow tests.
//
// Pass, all must hold:
//   1. first scan after reset: magic "jl", ready, n_up 0, free 255
//   2. 600 bytes down and 600 (+1) back up, in order, nothing lost or doubled,
//      with stray scans (all 0, all 1, random, a fake magic with a bad length)
//      in between that change nothing; down bytes reach the system side in
//      order and >= RX_GAP cycles apart
//   3. back-to-back scans: some come back ready=0 (rejected), still no loss
//   4. a scan with SEL low for A leaves A alone
//   5. B: a PC that honours `free` fills the 256-byte FIFO exactly, no overflow;
//      one that ignores it sets dn_overflow (port and flags bit 1)
// On the board, step J5 runs the real link over it (EXP-02 / EXP-04).
//==========================================================================
module jtag_link_bridge_tb;
    localparam int DR   = 1024;
    localparam int NB   = DR / 8;
    localparam int MAXD = NB - 4;
    localparam int GAPA = 32;

    // ---- clocks ----
    logic clk = 0, tck = 0;
    always #5 clk = ~clk;                       // 100 MHz
    logic rst_n = 0;

    // ---- shared TAP signals, one SEL per bridge ----
    logic sel_a = 0, sel_b = 0, capture = 0, shift = 0, update = 0, tdi = 0;
    wire  tdo_a, tdo_b;
    wire  tdo = sel_b ? tdo_b : tdo_a;

    // ---- bridge A + loopback service ----
    wire [7:0] rx_a; wire rxv_a, busy_a, ovf_a;
    logic [7:0] tx_a; logic txs_a;
    jtag_link_bridge #(.DR_BITS(DR), .RX_GAP(GAPA)) dut_a (
        .tck(tck), .sel(sel_a), .capture(capture), .shift(shift), .update(update), .tdi(tdi), .tdo(tdo_a),
        .clk(clk), .rst_n(rst_n), .rx_byte(rx_a), .rx_byte_valid(rxv_a),
        .tx_byte(tx_a), .tx_send(txs_a), .tx_busy(busy_a), .dn_overflow(ovf_a));
    assign tx_a  = rx_a + 8'd1;
    assign txs_a = rxv_a;

    // ---- bridge B: nothing drains it ----
    wire [7:0] rx_b; wire rxv_b, busy_b, ovf_b;
    jtag_link_bridge #(.DR_BITS(DR), .RX_GAP(1_000_000)) dut_b (
        .tck(tck), .sel(sel_b), .capture(capture), .shift(shift), .update(update), .tdi(tdi), .tdo(tdo_b),
        .clk(clk), .rst_n(rst_n), .rx_byte(rx_b), .rx_byte_valid(rxv_b),
        .tx_byte(8'h00), .tx_send(1'b0), .tx_busy(busy_b), .dn_overflow(ovf_b));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    // ---- system-side monitor of A: order + spacing of down bytes ----
    byte unsigned sys_seen[$];
    int last_rx_cyc = -1000, min_gap = 1 << 30, cyc = 0, busy_hits = 0;
    always @(posedge clk) begin
        cyc++;
        if (rxv_a) begin
            sys_seen.push_back(rx_a);
            if (cyc - last_rx_cyc < min_gap) min_gap = cyc - last_rx_cyc;
            last_rx_cyc = cyc;
            if (busy_a) busy_hits++;
        end
    end

    int b_drained = 0;                          // B hands one byte out at once (its gap counter starts at 0)
    always @(posedge clk) if (rxv_b) b_drained++;

    // ---- TAP model ----
    task automatic tck_edge();
        #33 tck = 1; #33 tck = 0;               // ~15 MHz, as measured in EXP-05
    endtask

    // one full scan of DR bits on the bridge `which` (0 = A, 1 = B, 2 = neither)
    task automatic scan(input logic [DR-1:0] din, output logic [DR-1:0] dout, input int which);
        repeat (12) tck_edge();                 // IR scan + state moves: TCK runs, SEL low
        sel_a = (which == 0); sel_b = (which == 1);
        capture = 1; tck_edge(); capture = 0;
        shift = 1;
        for (int i = 0; i < DR; i++) begin
            tdi = din[i];
            dout[i] = tdo;                      // TAP samples TDO on the falling edge
            tck_edge();
        end
        shift = 0;
        tck_edge();                             // Exit1-DR
        update = 1; tck_edge(); update = 0;     // Update-DR
        tck_edge();                             // Run-Test/Idle
        sel_a = 0; sel_b = 0;
    endtask

    // ---- PC model: the J4 transport's rules ----
    typedef struct {
        byte unsigned q[$];       // bytes waiting to go down
        byte unsigned got[$];     // bytes received up
        int  credit;              // down bytes we may send (free - n_dn of last accepted scan)
        int  n_ok, n_rej;
        int  last_acc;
        logic [7:0] flags;
    } pc_t;
    pc_t pa, pb;

    function automatic logic [7:0] byte_of(input logic [DR-1:0] v, input int i);
        return v[i*8 +: 8];
    endfunction

    task automatic pc_scan(inout pc_t p, input int which, input bit honour = 1, input int force_n = -1);
        logic [DR-1:0] din = '0, dout;
        int n = p.q.size();
        if (n > MAXD) n = MAXD;
        if (honour && n > p.credit) n = p.credit;
        if (force_n >= 0) n = force_n;
        din[7:0] = 8'h4A; din[15:8] = 8'h4C; din[23:16] = n[7:0];
        for (int i = 0; i < n; i++) din[(4 + i) * 8 +: 8] = (i < p.q.size()) ? p.q[i] : 8'hEE;
        scan(din, dout, which);
        if (byte_of(dout, 0) != 8'h6A || byte_of(dout, 1) != 8'h6C) begin
            $display("  FAIL: reply without magic: %h %h", byte_of(dout, 0), byte_of(dout, 1));
            fails++; checks++;
            return;
        end
        p.flags = byte_of(dout, 2);
        if (p.flags[0]) begin                   // ready at Capture -> this scan was accepted
            int n_up = byte_of(dout, 3);
            for (int i = 0; i < n && p.q.size() > 0; i++) void'(p.q.pop_front());
            for (int i = 0; i < n_up; i++) p.got.push_back(byte_of(dout, 8 + i));
            p.credit   = int'(byte_of(dout, 4)) - n;
            p.last_acc = byte_of(dout, 5);
            p.n_ok++;
        end else begin
            p.n_rej++;                          // rejected: nothing consumed, resend later
        end
    endtask

    task automatic stray(input int kind);
        logic [DR-1:0] din, dout;
        case (kind % 4)
            0: din = '0;
            1: din = '1;
            2: for (int i = 0; i < DR / 32; i++) din[i*32 +: 32] = $urandom;
            3: begin din = '0; din[7:0] = 8'h4A; din[15:8] = 8'h4C; din[23:16] = 8'd200; end  // bad length
        endcase
        scan(din, dout, 0);
    endtask

    byte unsigned sent[$];
    int acc_before;

    initial begin
        pa.credit = 0; pb.credit = 0;
        pa.n_ok = 0; pa.n_rej = 0; pb.n_ok = 0; pb.n_rej = 0;
        $display("== jtag_link_bridge_tb (DR_BITS=%0d, MAXD=%0d, MAXU=%0d) ==", DR, MAXD, NB - 8);
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (50) @(posedge clk);

        // ---- 1. first scan ----
        begin
            logic [DR-1:0] din = '0, dout;
            din[7:0] = 8'h4A; din[15:8] = 8'h4C;
            scan(din, dout, 0);
            check(byte_of(dout, 0) == 8'h6A && byte_of(dout, 1) == 8'h6C, "1. reply magic 'jl'");
            check(byte_of(dout, 2) == 8'h01, "1. flags = ready, no overflow");
            check(byte_of(dout, 3) == 0 && byte_of(dout, 4) == 255, "1. n_up 0, free 255 (256 saturated)");
            pa.credit = 255;
            #5000;
        end

        // ---- 2. 600 bytes through, stray scans in between ----
        for (int i = 0; i < 600; i++) begin
            sent.push_back(8'(i * 7 + 3));
            pa.q.push_back(8'(i * 7 + 3));
        end
        acc_before = pa.n_ok;
        for (int k = 0; k < 400 && (pa.q.size() > 0 || pa.got.size() < 600); k++) begin
            pc_scan(pa, 0);
            #5000;
            if (k % 3 == 1) begin stray(k); #5000; end
        end
        check(pa.got.size() == 600, $sformatf("2. 600 bytes back up (got %0d)", pa.got.size()));
        begin
            int bad = 0;
            for (int i = 0; i < pa.got.size() && i < 600; i++)
                if (pa.got[i] != 8'(sent[i] + 1)) bad++;
            check(bad == 0, $sformatf("2. every byte back as byte+1, in order (%0d wrong)", bad));
        end
        begin
            int bad = 0;
            for (int i = 0; i < sys_seen.size() && i < 600; i++) if (sys_seen[i] != sent[i]) bad++;
            check(sys_seen.size() == 600 && bad == 0, $sformatf("2. system side saw the 600 down bytes in order (%0d, %0d wrong)", sys_seen.size(), bad));
        end
        check(min_gap >= GAPA, $sformatf("2. down bytes >= RX_GAP=%0d cycles apart (min %0d)", GAPA, min_gap));
        check(busy_hits == 0, "2. loopback never saw tx_busy");
        check(pa.n_rej == 0, $sformatf("2. no rejected scans with 5 us between scans (%0d)", pa.n_rej));
        check(pa.last_acc == 8'(pa.n_ok), $sformatf("2. accepted counter = real scans only, strays ignored (%0d vs %0d)", pa.last_acc, pa.n_ok));
        check(!ovf_a && !pa.flags[1], "2. no down overflow");

        // ---- 3. back-to-back scans ----
        sent.delete(); pa.got.delete(); sys_seen.delete();
        for (int i = 0; i < 300; i++) begin
            sent.push_back(8'(i ^ 8'h5A));
            pa.q.push_back(8'(i ^ 8'h5A));
        end
        pa.n_rej = 0;
        for (int k = 0; k < 400 && (pa.q.size() > 0 || pa.got.size() < 300); k++) pc_scan(pa, 0);   // no gap
        check(pa.n_rej > 0, $sformatf("3. some back-to-back scans rejected (ready=0): %0d", pa.n_rej));
        begin
            int bad = 0;
            for (int i = 0; i < pa.got.size() && i < 300; i++) if (pa.got[i] != 8'(sent[i] + 1)) bad++;
            check(pa.got.size() == 300 && bad == 0, $sformatf("3. still all 300 bytes back, in order (%0d, %0d wrong)", pa.got.size(), bad));
        end

        // ---- 4. SEL low for A ----
        begin
            int acc0 = pa.last_acc;
            logic [DR-1:0] din = '0, dout;
            din[7:0] = 8'h4A; din[15:8] = 8'h4C; din[23:16] = 8'd3; din[39:32] = 8'h77;
            #5000;
            scan(din, dout, 2);                 // neither SEL
            #5000;
            pc_scan(pa, 0);                     // n_dn 0
            check(pa.last_acc == 8'(acc0 + 1), "4. scan with SEL low: not counted by A");
            #20000;
            check(sys_seen.size() == 300, "4. ... and no bytes injected");
        end

        // ---- 5. bridge B: credit and overflow ----
        for (int i = 0; i < 400; i++) pb.q.push_back(8'(i));
        pc_scan(pb, 1);                         // learn `free`
        #5000;
        for (int k = 0; k < 20; k++) begin pc_scan(pb, 1); #5000; end
        check(400 - pb.q.size() == 256 + b_drained, $sformatf("5. honouring `free`: sent exactly FIFO depth 256 + %0d drained (%0d sent)", b_drained, 400 - pb.q.size()));
        check(!ovf_b && !pb.flags[1], "5. ... without overflow");
        check(pb.credit == 0, "5. ... credit now 0");
        pc_scan(pb, 1, 0, 10);                  // ignore credit: 10 more bytes
        #5000;
        pc_scan(pb, 1, 1, 0);
        check(ovf_b && pb.flags[1], "5. ignoring `free` sets dn_overflow (port + flags bit 1)");

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $finish;
    end
endmodule
