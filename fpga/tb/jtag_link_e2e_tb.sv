`timescale 1ns / 1ps
//==========================================================================
// jtag_link_e2e_tb
//
// JTAG link step J3, end to end in simulation: the two JTAG link tops
// (phase5_link_jtag_top, phase7_link_jtag_top), UNMODIFIED, with only the
// BSCANE2 primitive replaced by fpga/tb/bscane2_sim_stub.sv. A PC model does
// full-length USER4 scans by the transport rules (docs/link_register_map.md,
// "Transport: JTAG over J17") and talks real link frames:
//   PC -> scans -> jtag_link_bridge -> link_frame -> link_ctrl / v2 registers
//      -> response frames -> scans -> PC.
//
// Pass:
//   Phase 5 top: STATUS (run 0); SCRATCH write + read back; configure the
//     test clock cell over the link, APPLY + RUN, period 20 ticks on LA00;
//     then WHILE RUNNING new period + APPLY, period 40 ticks (Phase 5's exit
//     criterion, now over JTAG); a bad-checksum frame gets a NACK; STOP ->
//     run 0. Stray scans in between change nothing.
//   Phase 7 top: STATUS; SCRATCH write + read back; N_STEPS write + read back.
// On the board this is step J5 (EXP-02 / EXP-04 over JTAG).
//==========================================================================

// one wrapper per top: its own jtag_tap (the stub finds it by name) + jumpers
module e2e_p5_wrap (
    input  logic clk,
    input  logic tck, sel, capture, shift, update, tdi,
    output logic tdo,
    output logic la00
);
    wire [31:0] fmc_pins;
    jtag_tap_model jtag_tap (.tck(tck), .sel(sel), .capture(capture), .shift(shift),
                             .update(update), .tdi(tdi), .tdo(tdo));
    phase5_link_jtag_top dut (.clk(clk), .sw(3'b000), .led(), .fmc_pins(fmc_pins));
    genvar g;
    for (g = 0; g < 5; g++) begin : g_jumper
        assign fmc_pins[16 + g] = fmc_pins[g];
    end
    assign la00 = fmc_pins[0];
endmodule

module e2e_p7_wrap (
    input  logic clk,
    input  logic tck, sel, capture, shift, update, tdi,
    output logic tdo
);
    wire [31:0] fmc_pins;
    jtag_tap_model jtag_tap (.tck(tck), .sel(sel), .capture(capture), .shift(shift),
                             .update(update), .tdi(tdi), .tdo(tdo));
    phase7_link_jtag_top dut (.clk(clk), .led(), .fmc_pins(fmc_pins));
    genvar g;
    for (g = 0; g < 5; g++) begin : g_jumper
        assign fmc_pins[16 + g] = fmc_pins[g];
    end
endmodule

module jtag_link_e2e_tb;
    localparam int DR   = 1024;
    localparam int MAXD = DR / 8 - 4;

    logic clk = 0, tck = 0;
    always #5 clk = ~clk;
    logic sel5 = 0, sel7 = 0, capture = 0, shift = 0, update = 0, tdi = 0;
    wire  tdo5, tdo7, la00;
    wire  tdo = sel7 ? tdo7 : tdo5;

    e2e_p5_wrap w5 (.clk(clk), .tck(tck), .sel(sel5), .capture(capture), .shift(shift),
                    .update(update), .tdi(tdi), .tdo(tdo5), .la00(la00));
    e2e_p7_wrap w7 (.clk(clk), .tck(tck), .sel(sel7), .capture(capture), .shift(shift),
                    .update(update), .tdi(tdi), .tdo(tdo7));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    // ---------------- TAP + transport (the J4 rules) ----------------
    task automatic tck_edge();
        #33 tck = 1; #33 tck = 0;
    endtask

    task automatic scan(input logic [DR-1:0] din, output logic [DR-1:0] dout, input int t);
        repeat (12) tck_edge();
        sel5 = (t == 5); sel7 = (t == 7);
        capture = 1; tck_edge(); capture = 0;
        shift = 1;
        for (int i = 0; i < DR; i++) begin tdi = din[i]; dout[i] = tdo; tck_edge(); end
        shift = 0;
        tck_edge();
        update = 1; tck_edge(); update = 0;
        tck_edge();
        sel5 = 0; sel7 = 0;
    endtask

    byte unsigned downq[int][$];   // per top (5 / 7)
    byte unsigned upq[int][$];
    int           credit[int];

    task automatic transport_scan(input int t);
        logic [DR-1:0] din = '0, dout;
        int n = downq[t].size();
        if (n > MAXD) n = MAXD;
        if (n > credit[t]) n = credit[t];
        din[7:0] = 8'h4A; din[15:8] = 8'h4C; din[23:16] = n[7:0];
        for (int i = 0; i < n; i++) din[(4 + i) * 8 +: 8] = downq[t][i];
        scan(din, dout, t);
        if (dout[7:0] != 8'h6A || dout[15:8] != 8'h6C) begin
            check(0, $sformatf("top %0d: reply magic", t));
            return;
        end
        if (dout[16]) begin                      // ready -> accepted
            for (int i = 0; i < n; i++) void'(downq[t].pop_front());
            for (int i = 0; i < dout[31:24]; i++) upq[t].push_back(dout[(8 + i) * 8 +: 8]);
            credit[t] = int'(dout[39:32]) - n;
        end
        #5000;                                   // a real PC polls ~1.3 ms apart; 5 us is plenty here
    endtask

    task automatic stray(input int t);
        logic [DR-1:0] din, dout;
        for (int i = 0; i < DR / 32; i++) din[i*32 +: 32] = $urandom;
        scan(din, dout, t);
        #5000;
    endtask

    // ---------------- link frames ----------------
    task automatic send_frame(input int t, input logic [7:0] cmd, input logic [15:0] addr,
                              input byte unsigned data[$], input int len_field = -1, input bit bad_ck = 0);
        byte unsigned f[$];
        logic [7:0] ck;
        int len = (len_field >= 0) ? len_field : data.size();
        f.push_back(8'hAA); f.push_back(cmd); f.push_back(addr[7:0]); f.push_back(addr[15:8]);
        f.push_back(8'(len));
        ck = cmd ^ addr[7:0] ^ addr[15:8] ^ 8'(len);
        for (int i = 0; i < data.size(); i++) begin f.push_back(data[i]); ck ^= data[i]; end
        f.push_back(bad_ck ? ~ck : ck);
        foreach (f[i]) downq[t].push_back(f[i]);
    endtask

    // pump scans until the down queue is empty, plus `extra` more (lets the FPGA act)
    task automatic flush(input int t, input int extra = 2);
        for (int k = 0; k < 50 && downq[t].size() > 0; k++) transport_scan(t);
        repeat (extra) transport_scan(t);
    endtask

    // pump until one complete response frame is in upq[t], parse and remove it
    task automatic get_response(input int t, output logic [7:0] cmd, output logic [15:0] addr,
                                output byte unsigned data[$], output bit ok);
        ok = 0; data.delete();
        for (int k = 0; k < 60; k++) begin
            while (upq[t].size() > 0 && upq[t][0] != 8'hAA) void'(upq[t].pop_front());
            if (upq[t].size() >= 6 && upq[t].size() >= 6 + upq[t][4]) begin
                logic [7:0] ck = 0;
                int len = upq[t][4];
                cmd  = upq[t][1];
                addr = {upq[t][3], upq[t][2]};
                for (int i = 1; i < 5 + len; i++) ck ^= upq[t][i];
                for (int i = 0; i < len; i++) data.push_back(upq[t][5 + i]);
                ok = (ck == upq[t][5 + len]);
                repeat (6 + len) void'(upq[t].pop_front());
                return;
            end
            transport_scan(t);
        end
    endtask

    task automatic request(input int t, input logic [7:0] cmd, input logic [15:0] addr, input int len,
                           output logic [7:0] rcmd, output byte unsigned rdata[$], output bit ok);
        byte unsigned dummy[$];
        logic [15:0] raddr;
        for (int i = 0; i < len; i++) dummy.push_back(8'h00);   // reads carry LEN dummy bytes
        send_frame(t, cmd, addr, dummy, len);
        flush(t, 0);
        get_response(t, rcmd, raddr, rdata, ok);
    endtask

    task automatic write_u32(input int t, input logic [15:0] addr, input int v);
        byte unsigned d[$];
        d.push_back(8'(v)); d.push_back(8'(v >> 8)); d.push_back(8'(v >> 16)); d.push_back(8'(v >> 24));
        send_frame(t, 8'h01, addr, d);
    endtask

    task automatic measure_period(output int p);
        int t1 = -1, n = 0; logic prev = la00;
        p = -1;
        for (int i = 0; i < 4000; i++) begin
            @(posedge clk);
            if (la00 && !prev) begin
                n++;
                if (n == 2) t1 = i;
                if (n == 3) begin p = i - t1; return; end   // skip the first (may be a partial period)
            end
            prev = la00;
        end
    endtask

    logic [7:0] rc;
    byte unsigned rd[$], one[$], none[$];   // none: empty payload (APPLY / RUN / STOP / STATUS)
    bit ok;
    int per;

    initial begin
        credit[5] = 0; credit[7] = 0;
        $display("== jtag_link_e2e_tb: link frames over JTAG scans, both link tops ==");
        repeat (100) @(posedge clk);
        transport_scan(5); transport_scan(7);     // learn `free`

        // ---------------- Phase 5 top ----------------
        $display("\n-- phase5_link_jtag_top --");
        request(5, 8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rc == 8'h07 && rd.size() == 1 && rd[0][0] == 1'b0, "P5 STATUS: response, checksum ok, run = 0");

        stray(5); stray(5);
        one.delete(); one.push_back(8'h5A);
        send_frame(5, 8'h01, 16'h0000, one);
        flush(5);
        stray(5);
        request(5, 8'h02, 16'h0000, 1, rc, rd, ok);
        check(ok && rc == 8'h02 && rd.size() == 1 && rd[0] == 8'h5A, "P5 SCRATCH 0x5A written and read back (stray scans around it)");

        one.delete(); one.push_back(8'b0000_0011);          // CTRL: CLOCK, idle 0
        send_frame(5, 8'h01, 16'h0010, one);
        write_u32(5, 16'h0015, 20);                          // PARAM_A = period
        write_u32(5, 16'h0019, 10);                          // PARAM_B = high time
        flush(5);
        request(5, 8'h02, 16'h0015, 4, rc, rd, ok);
        check(ok && rd.size() == 4 && rd[0] == 20 && rd[1] == 0, "P5 PARAM_A read back = 20");
        send_frame(5, 8'h04, 16'h0000, none);   // APPLY (empty payload)
        send_frame(5, 8'h05, 16'h0000, none);   // RUN
        flush(5);
        request(5, 8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0][0] == 1'b1, "P5 STATUS after RUN: run = 1");
        measure_period(per);
        check(per == 20, $sformatf("P5 LA00 period = %0d ticks (expected 20)", per));

        write_u32(5, 16'h0015, 40);
        write_u32(5, 16'h0019, 20);
        send_frame(5, 8'h04, 16'h0000, none);   // APPLY while still RUNning
        flush(5);
        measure_period(per);
        check(per == 40, $sformatf("P5 after a live APPLY over JTAG: period = %0d ticks (expected 40)", per));

        send_frame(5, 8'h07, 16'h0000, none, 0, 1);   // STATUS with a bad checksum
        flush(5, 0);
        begin logic [15:0] a; get_response(5, rc, a, rd, ok); end
        check(ok && rc == 8'hFF, "P5 bad checksum -> NACK (0xFF)");

        send_frame(5, 8'h06, 16'h0000, none);   // STOP
        flush(5);
        request(5, 8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0][0] == 1'b0, "P5 STATUS after STOP: run = 0");

        // ---------------- Phase 7 top ----------------
        $display("\n-- phase7_link_jtag_top --");
        request(7, 8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rc == 8'h07 && rd.size() == 1 && rd[0][1] == 1'b0, "P7 STATUS: response, checksum ok, not busy");
        one.delete(); one.push_back(8'hA7);
        send_frame(7, 8'h01, 16'h0000, one);
        flush(7);
        request(7, 8'h02, 16'h0000, 1, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0] == 8'hA7, "P7 SCRATCH 0xA7 written and read back");
        one.delete(); one.push_back(8'd3);
        send_frame(7, 8'h01, phase7_link_pkg::REG_N_STEPS, one);
        flush(7);
        request(7, 8'h02, phase7_link_pkg::REG_N_STEPS, 1, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0] == 8'd3, "P7 N_STEPS = 3 written and read back");

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $finish;
    end
endmodule
