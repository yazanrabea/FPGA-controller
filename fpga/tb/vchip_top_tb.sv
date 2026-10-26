`timescale 1ns / 1ps
//==========================================================================
// vchip_top_tb
//
// Chip pipeline step C6 / EXP-08 in simulation: vchip_top (chip_top + the
// virtual chip built from Dima's UNMODIFIED sipo / sipo_wrapper / piso2) with
// the jumper wires of config/exp08_vchip.yaml modelled as wires (vchip_pkg
// VC_SRC / VC_DST). Only BSCANE2 is replaced (bscane2_sim_stub.sv); the PC
// model and transport are chip_top_tb's. Table: config/chip_sim_test.yaml.
//
// One testbench-only addition: after the first APPLY the testbench pulls the
// virtual chip's rst_sipo wire low once for 1 us. Reason: in simulation every
// register starts at X, and sipo_wrapper loads sel[23:8] from parallel_out at
// the reset edge (Dima Q1), so the power-up reset leaves sel[23:8] = X. On the
// board registers start at 0. The second reset, with parallel_out already 0,
// gives the board's starting point (sel = 0) in simulation too.
//
// The sequence and the expected 168-bit readback come from scripts/run_vchip_sim.sh
// (packages chip_tb_pkg and vchip_tb_expect::WANT): config/chip_sim_test.yaml ->
// {frame, 0000, E7, C6}; config/exp08_phirst.yaml -> {frame, F0C3, E7, C6};
// config/exp08_sel_reset.yaml -> {0, C3E7, 00, C6}. WANT = {frame at the read,
// sel[23:0], 8'hC6}, so the frame and sipo_out checks use WANT's frame part.
//
// Pass, all must hold:
//   1. STATUS answers over JTAG, idle.  2. The 3-step table loads, N_STEPS = 3.
//   3. Before RUN: ctl_out at step 0 (reset / rst_sipo / rst_piso high, rest low);
//      after the extra reset the virtual chip's frame and sel are 0.
//   4. RUN: Dima's sipo holds WANT's frame part at the end (= the config's frame unless
//      the sequence resets it after the load).
//   5. STATUS done, no fault; LD4 on, LD5 / LD7 off.
//   6. READ_CAPTURE piso_out = WANT: the frame went PC -> controller -> jumpers ->
//      Dima's SIPO -> PISO -> back.
//   7. sipo_out's cap cell reads level = WANT's frame bit 0 (sipo_wrapper's shift_reg[0]).
// On the board: EXP-08 (docs/experiments/EXP-08_virtual_chip.md).
//==========================================================================

module vchip_wrap (
    input  logic clk,
    input  logic tck, sel, capture, shift, update, tdi,
    output logic tdo,
    output logic [7:0] led,
    output logic [vchip_pkg::N_CTL-1:0] ctl_out,
    input  logic [chip_pkg::N_CAP-1:0]  ctl_in,
    input  logic [7:0] vc_in,
    output logic [1:0] vc_out
);
    jtag_tap_model jtag_tap (.tck(tck), .sel(sel), .capture(capture), .shift(shift),
                             .update(update), .tdi(tdi), .tdo(tdo));
    vchip_top dut (.clk(clk), .led(led), .ctl_out(ctl_out), .ctl_in(ctl_in),
                   .vc_in(vc_in), .vc_out(vc_out));
endmodule

module vchip_top_tb;
    localparam int DR   = 1024;
    localparam int MAXD = DR / 8 - 4;
    localparam int NC   = chip_pkg::N_CAP;
    localparam int NCTL = vchip_pkg::N_CTL;
    localparam logic [167:0] WANT  = vchip_tb_expect::WANT;      // {frame, sel[23:0], 8'hC6} at the read
    localparam logic [135:0] FRAME = WANT[167:32];              // what Dima's sipo holds at the read

    logic clk = 0, tck = 0;
    always #5 clk = ~clk;
    logic sel = 0, capture = 0, shift = 0, update = 0, tdi = 0;
    wire  tdo;
    wire  [7:0] led;
    wire  [NCTL-1:0] ctl_out;
    wire  [NC-1:0]   ctl_in;
    wire  [7:0]      vc_in;
    wire  [1:0]      vc_out;

    // ---- the jumper wires (vchip_pkg::VC_SRC / VC_DST = config/exp08_vchip.yaml) ----
    logic extra_rst_n = 1'b1;                    // testbench-only second reset, see header
    genvar k;
    generate
        for (k = 0; k < 8; k++) begin : g_jin
            if (k == 3) begin : g_rst            // vc_in[3] = rst_sipo
                assign vc_in[k] = ctl_out[vchip_pkg::VC_SRC[k]] & extra_rst_n;
            end else begin : g_wire
                assign vc_in[k] = ctl_out[vchip_pkg::VC_SRC[k]];
            end
        end
        for (k = 0; k < NC; k++) begin : g_jout
            if (k == vchip_pkg::VC_DST[0]) begin : g_so
                assign ctl_in[k] = vc_out[0];
            end else if (k == vchip_pkg::VC_DST[1]) begin : g_po
                assign ctl_in[k] = vc_out[1];
            end else begin : g_none
                assign ctl_in[k] = 1'b0;         // nothing there (PULLDOWN)
            end
        end
    endgenerate

    vchip_wrap w (.clk(clk), .tck(tck), .sel(sel), .capture(capture), .shift(shift),
                  .update(update), .tdi(tdi), .tdo(tdo), .led(led), .ctl_out(ctl_out), .ctl_in(ctl_in),
                  .vc_in(vc_in), .vc_out(vc_out));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    function automatic int ctl_of(input int sig);   // ctl_out index of chip_top sig cell `sig`
        for (int i = 0; i < NCTL; i++) if (vchip_pkg::CTL_SIG[i] == sig) return i;
        return -1;
    endfunction

    // ---------------- TAP + transport (the J4 rules, as chip_top_tb) ----------------
    task automatic tck_edge();
        #33 tck = 1; #33 tck = 0;
    endtask

    task automatic scan(input logic [DR-1:0] din, output logic [DR-1:0] dout);
        repeat (12) tck_edge();
        sel = 1;
        capture = 1; tck_edge(); capture = 0;
        shift = 1;
        for (int i = 0; i < DR; i++) begin tdi = din[i]; dout[i] = tdo; tck_edge(); end
        shift = 0;
        tck_edge();
        update = 1; tck_edge(); update = 0;
        tck_edge();
        sel = 0;
    endtask

    byte unsigned downq[$], upq[$];
    int credit = 0;

    task automatic transport_scan();
        logic [DR-1:0] din = '0, dout;
        int n = downq.size();
        if (n > MAXD) n = MAXD;
        if (n > credit) n = credit;
        din[7:0] = 8'h4A; din[15:8] = 8'h4C; din[23:16] = n[7:0];
        for (int i = 0; i < n; i++) din[(4 + i) * 8 +: 8] = downq[i];
        scan(din, dout);
        if (dout[7:0] != 8'h6A || dout[15:8] != 8'h6C) begin check(0, "reply magic"); return; end
        if (dout[16]) begin
            for (int i = 0; i < n; i++) void'(downq.pop_front());
            for (int i = 0; i < dout[31:24]; i++) upq.push_back(dout[(8 + i) * 8 +: 8]);
            credit = int'(dout[39:32]) - n;
        end
        #5000;
    endtask

    task automatic send_frame(input logic [7:0] cmd, input logic [15:0] addr, input byte unsigned data[$],
                              input int len_field = -1);
        logic [7:0] ck;
        int len = (len_field >= 0) ? len_field : data.size();
        downq.push_back(8'hAA); downq.push_back(cmd); downq.push_back(addr[7:0]); downq.push_back(addr[15:8]);
        downq.push_back(8'(len));
        ck = cmd ^ addr[7:0] ^ addr[15:8] ^ 8'(len);
        foreach (data[i]) begin downq.push_back(data[i]); ck ^= data[i]; end
        downq.push_back(ck);
    endtask

    task automatic flush(input int extra = 2);
        for (int j = 0; j < 400 && downq.size() > 0; j++) transport_scan();
        repeat (extra) transport_scan();
    endtask

    task automatic get_response(output logic [7:0] cmd, output byte unsigned data[$], output bit ok);
        ok = 0; data.delete();
        for (int j = 0; j < 60; j++) begin
            while (upq.size() > 0 && upq[0] != 8'hAA) void'(upq.pop_front());
            if (upq.size() >= 6 && upq.size() >= 6 + upq[4]) begin
                logic [7:0] ck = 0;
                int len = upq[4];
                cmd = upq[1];
                for (int i = 1; i < 5 + len; i++) ck ^= upq[i];
                for (int i = 0; i < len; i++) data.push_back(upq[5 + i]);
                ok = (ck == upq[5 + len]);
                repeat (6 + len) void'(upq.pop_front());
                return;
            end
            transport_scan();
        end
    endtask

    task automatic request(input logic [7:0] cmd, input logic [15:0] addr, input int len,
                           output logic [7:0] rcmd, output byte unsigned rdata[$], output bit ok);
        byte unsigned dummy[$];
        for (int i = 0; i < len; i++) dummy.push_back(8'h00);   // reads carry LEN dummy bytes
        send_frame(cmd, addr, dummy, len);
        flush(0);
        get_response(rcmd, rdata, ok);
    endtask

    logic [7:0] rc;
    byte unsigned rd[$], one[$], none[$];
    bit ok;

    initial begin
        $display("== vchip_top_tb: controller (%0d pinned outputs) + virtual chip, %0d-step table, expect %h ==",
                 NCTL, chip_tb_pkg::N_STEPS, WANT);
        repeat (100) @(posedge clk);
        transport_scan();                        // learn `free`

        // 1. STATUS
        request(8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rc == 8'h07 && rd.size() == 1 && rd[0][1] == 1'b0, "1. STATUS over JTAG: answered, not busy");

        // 2. the table, in <= 128-byte frames (as SeqLink.load)
        for (int t = 0; t < chip_tb_pkg::N_STEPS; t++) begin
            for (int o = 0; o < chip_tb_pkg::USED_BYTES; o += 128) begin
                automatic byte unsigned d[$];
                for (int b = o; b < o + 128 && b < chip_tb_pkg::USED_BYTES; b++)
                    d.push_back(chip_tb_pkg::TABLE[(t * chip_pkg::ENTRY_BYTES + b) * 8 +: 8]);
                send_frame(8'h01, chip_pkg::TABLE_BASE + t * chip_pkg::ENTRY_BYTES + o, d);
                flush(0);
            end
        end
        one.delete(); one.push_back(8'(chip_tb_pkg::N_STEPS));
        send_frame(8'h01, chip_pkg::REG_N_STEPS, one);
        send_frame(8'h04, 16'h0000, none);       // APPLY: step 0 = idle state
        flush();
        request(8'h02, chip_pkg::REG_N_STEPS, 1, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0] == chip_tb_pkg::N_STEPS,
              $sformatf("2. table loaded, N_STEPS read back = %0d", chip_tb_pkg::N_STEPS));

        // 3. idle levels on the pinned outputs, then the testbench's second reset
        begin
            automatic logic [NCTL-1:0] want = '0;
            want[ctl_of(chip_pkg::SIG_RESET)]    = 1'b1;
            want[ctl_of(chip_pkg::SIG_RST_SIPO)] = 1'b1;
            want[ctl_of(chip_pkg::SIG_RST_PISO)] = 1'b1;
            check(ctl_out === want, $sformatf("3. before RUN every ctl_out at step 0's level (got %b)", ctl_out));
        end
        extra_rst_n = 1'b0; #1000; extra_rst_n = 1'b1; #1000;
        check(w.dut.u_vc.frame === '0 && w.dut.u_vc.sel === '0,
              $sformatf("3. virtual chip after the second reset: frame %h, sel %h (board power-up = 0)",
                        w.dut.u_vc.frame, w.dut.u_vc.sel));

        // 4. RUN; the sequences take ~330-345 us
        send_frame(8'h05, 16'h0000, none);
        flush(0);
        #420000;
        check(w.dut.u_vc.frame === FRAME,
              $sformatf("4. Dima's sipo holds the expected frame at the end (%h)", w.dut.u_vc.frame));

        // 5. status, LEDs
        request(8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0][2] && !rd[0][3] && !rd[0][1], $sformatf("5. STATUS: done, no fault, not busy (%b)", rd[0]));
        check(led[4] && !led[5] && !led[7], $sformatf("5. LD4 done on, LD5 fault / LD7 link error off (led=%b)", led));

        // 6. the 168 bits back
        request(8'h08, 16'(chip_pkg::PISO_CELL * chip_pkg::CAP_STRIDE + chip_pkg::CAP_DATA), chip_pkg::CAP_BYTES, rc, rd, ok);
        begin
            automatic logic [167:0] got = '0;
            for (int i = 0; i < rd.size() && i < 21; i++) got[i*8 +: 8] = rd[i];
            check(ok && rd.size() == 21 && got === WANT,
                  $sformatf("6. READ_CAPTURE piso_out = {frame, sel, C6}: got %h, want %h", got, WANT));
        end

        // 7. sipo_out level (flags byte, bit 0)
        request(8'h08, 16'(chip_pkg::CAP_SIPO_OUT * chip_pkg::CAP_STRIDE), 1, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0][0] == FRAME[0],
              $sformatf("7. sipo_out level = frame[0] = %0d (flags %b)", FRAME[0], rd[0]));

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $finish;
    end
endmodule
