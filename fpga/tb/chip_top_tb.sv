`timescale 1ns / 1ps
//==========================================================================
// chip_top_tb
//
// Chip pipeline step C4: chip_top end to end in simulation. chip_top is
// unmodified; only the BSCANE2 primitive is replaced (fpga/tb/bscane2_sim_stub.sv).
// A PC model does full-length USER4 scans by the transport rules
// (docs/link_register_map.md) and talks real link frames, like jtag_link_e2e_tb.
//
// The table is config/chip_sim_test.yaml, encoded by
// `gen_svh.py --chip --table-out` into package chip_tb_pkg (scripts/run_chip_sim.sh).
//
// Pass, all must hold:
//   1. STATUS answers over JTAG, idle.
//   2. The 3-step table loads in <= 128-byte frames (as SeqLink.load does), N_STEPS, APPLY.
//   3. Before RUN every chip_out sits at step 0's level (reset / rst_sipo / rst_piso high,
//      the 19 others low).
//   4. RUN: sipo_in sampled on each clk_sipo rising edge = the 136-bit frame of the config,
//      exactly 136 rising edges; cs pulses only after the last one; sipo_in never changes
//      within 200 ns of a clk_sipo rising edge (setup / hold margin, proves the edge choice).
//   5. A PISO model (one bit of a known 168-bit pattern per clk_piso rising edge, like the
//      chip) is captured by piso_out's cap cell; READ_CAPTURE over JTAG returns all 168 bits.
//   6. STATUS = done, LD4 on, no fault / link error.
// On the board: EXP-07 (pins on the logic analyser) and EXP-08 (Dima's models as the chip).
//==========================================================================

module chip_wrap (
    input  logic clk,
    input  logic tck, sel, capture, shift, update, tdi,
    output logic tdo,
    output logic [7:0] led,
    output logic [chip_pkg::N_SIG-1:0] chip_out,
    input  logic [chip_pkg::N_CAP-1:0] chip_in
);
    jtag_tap_model jtag_tap (.tck(tck), .sel(sel), .capture(capture), .shift(shift),
                             .update(update), .tdi(tdi), .tdo(tdo));
    chip_top dut (.clk(clk), .led(led), .chip_out(chip_out), .chip_in(chip_in));
endmodule

module chip_top_tb;
    localparam int DR   = 1024;
    localparam int MAXD = DR / 8 - 4;
    localparam int NS   = chip_pkg::N_SIG;
    localparam int NC   = chip_pkg::N_CAP;
    localparam int PISO_W = chip_pkg::CAP_W[chip_pkg::PISO_CELL];
    localparam logic [167:0] PISO_PATTERN = 168'hC0FFEE_123456789ABCDEF0_0F1E2D3C4B5A6978_A5A5;   // 42 hex digits

    logic clk = 0, tck = 0;
    always #5 clk = ~clk;
    logic sel = 0, capture = 0, shift = 0, update = 0, tdi = 0;
    wire  tdo;
    wire  [7:0] led;
    wire  [NS-1:0] chip_out;
    logic [NC-1:0] chip_in = '0;

    chip_wrap w (.clk(clk), .tck(tck), .sel(sel), .capture(capture), .shift(shift),
                 .update(update), .tdi(tdi), .tdo(tdo), .led(led), .chip_out(chip_out), .chip_in(chip_in));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    // ---------------- the "chip" side: watch SIPO, model PISO ----------------
    wire clk_sipo = chip_out[chip_pkg::SIG_CLK_SIPO];
    wire sipo_in  = chip_out[chip_pkg::SIG_SIPO_IN];
    wire cs       = chip_out[chip_pkg::SIG_CS];
    wire clk_piso = chip_out[chip_pkg::SIG_CLK_PISO];
    // `armed` from RUN on: before a table is loaded the step RAM is uninitialised in simulation
    // (block RAM powers up as 0 on the board), so the power-up preload sends the pins 0 -> X,
    // which Verilog counts as a posedge. Counting from RUN is what this test means anyway.
    logic armed = 0;
    logic [135:0] sipo_seen = '0;
    int sipo_edges = 0, cs_rise_after = -1, piso_edges = 0;
    logic cs_d = 0;
    always @(posedge clk_sipo) if (armed) begin    // the chip's SIPO samples on the rising edge
        sipo_seen = {sipo_seen[134:0], sipo_in};
        sipo_edges++;
    end
    always @(posedge clk) begin
        if (armed && cs && !cs_d) cs_rise_after = sipo_edges; // clk_sipo edges before cs rose
        cs_d <= cs;
    end
    // Setup / hold margin of sipo_in around the chip's sampling edge (clk_sipo rising). Right
    // bits alone don't prove the edge choice: data changing 20 ns after the rising edge (wrong
    // edge) still reads back right in a zero-delay simulation, but leaves the chip 20 ns of
    // hold. With data on the falling edge, both margins are ~half a period (~480 ns at 1 MHz).
    localparam realtime MIN_MARGIN_NS = 200;
    realtime t_sipo_change = 0, t_sipo_edge = -1e9, min_setup = 1e9, min_hold = 1e9;
    always @(sipo_in) if (armed) begin
        if ($realtime - t_sipo_edge < min_hold) min_hold = $realtime - t_sipo_edge;
        t_sipo_change = $realtime;
    end
    always @(posedge clk_sipo) if (armed) begin
        if ($realtime - t_sipo_change < min_setup) min_setup = $realtime - t_sipo_change;
        t_sipo_edge = $realtime;
    end
    always @(posedge clk_piso) if (armed) begin    // the chip's PISO: one bit per rising edge
        if (piso_edges < PISO_W) chip_in[chip_pkg::CAP_PISO_OUT] <= PISO_PATTERN[PISO_W - 1 - piso_edges];
        piso_edges++;
    end

    // ---------------- TAP + transport (the J4 rules) ----------------
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
        for (int k = 0; k < 400 && downq.size() > 0; k++) transport_scan();
        repeat (extra) transport_scan();
    endtask

    task automatic get_response(output logic [7:0] cmd, output byte unsigned data[$], output bit ok);
        ok = 0; data.delete();
        for (int k = 0; k < 60; k++) begin
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
        $display("== chip_top_tb: %0d chip_out + %0d chip_in, table from config/chip_sim_test.yaml ==", NS, NC);
        repeat (100) @(posedge clk);
        transport_scan();                        // learn `free`

        // 1. STATUS
        request(8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rc == 8'h07 && rd.size() == 1 && rd[0][1] == 1'b0, "1. STATUS over JTAG: answered, not busy");

        // 2. load the table in <= 128-byte frames, N_STEPS, APPLY
        for (int k = 0; k < chip_tb_pkg::N_STEPS; k++) begin
            for (int o = 0; o < chip_tb_pkg::USED_BYTES; o += 128) begin
                // automatic: a block variable in an initial block is static by default, so it
                // would keep growing across iterations (it did: frames of 256+ bytes, LEN wrapped)
                automatic byte unsigned d[$];
                for (int b = o; b < o + 128 && b < chip_tb_pkg::USED_BYTES; b++)
                    d.push_back(chip_tb_pkg::TABLE[(k * chip_pkg::ENTRY_BYTES + b) * 8 +: 8]);
                send_frame(8'h01, chip_pkg::TABLE_BASE + k * chip_pkg::ENTRY_BYTES + o, d);
                flush(0);
            end
        end
        one.delete(); one.push_back(8'(chip_tb_pkg::N_STEPS));
        send_frame(8'h01, chip_pkg::REG_N_STEPS, one);
        send_frame(8'h04, 16'h0000, none);       // APPLY: step 0 = idle state
        flush();
        request(8'h02, chip_pkg::REG_N_STEPS, 1, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0] == chip_tb_pkg::N_STEPS, "2. table loaded, N_STEPS read back = 3");

        // 3. idle levels
        begin
            automatic logic [NS-1:0] want = '0;
            want[chip_pkg::SIG_RESET] = 1'b1;
            want[chip_pkg::SIG_RST_SIPO] = 1'b1;
            want[chip_pkg::SIG_RST_PISO] = 1'b1;
            check(chip_out === want, $sformatf("3. before RUN every chip_out at step 0's level (got %b)", chip_out));
        end

        // 4./5. RUN; the sequence takes ~330 us
        armed = 1;
        send_frame(8'h05, 16'h0000, none);
        flush(0);
        #400000;
        check(sipo_edges == 136, $sformatf("4. exactly 136 clk_sipo rising edges (%0d)", sipo_edges));
        check(sipo_seen == chip_tb_pkg::SIPO_FRAME,
              $sformatf("4. sipo_in = the 136-bit frame from the config (%h)", sipo_seen));
        check(cs_rise_after == 136, $sformatf("4. cs rose only after the 136th clk_sipo edge (%0d)", cs_rise_after));
        check(min_setup >= MIN_MARGIN_NS && min_hold >= MIN_MARGIN_NS,
              $sformatf("4. sipo_in setup / hold around clk_sipo rising >= %0.0f ns (min setup %0.0f ns, min hold %0.0f ns)",
                        MIN_MARGIN_NS, min_setup, min_hold));
        check(piso_edges == 168, $sformatf("5. exactly 168 clk_piso rising edges (%0d)", piso_edges));

        request(8'h07, 16'h0000, 0, rc, rd, ok);
        check(ok && rd.size() == 1 && rd[0][2] && !rd[0][3] && !rd[0][1], $sformatf("6. STATUS: done, no fault, not busy (%b)", rd[0]));

        request(8'h08, 16'(chip_pkg::PISO_CELL * chip_pkg::CAP_STRIDE + chip_pkg::CAP_DATA), chip_pkg::CAP_BYTES, rc, rd, ok);
        begin
            automatic logic [167:0] got = '0;
            for (int i = 0; i < rd.size() && i < 21; i++) got[i*8 +: 8] = rd[i];
            check(ok && rd.size() == 21 && got == PISO_PATTERN,
                  $sformatf("5. READ_CAPTURE piso_out over JTAG = the 168-bit pattern (%h)", got));
        end
        check(led[4] && !led[5] && !led[7], $sformatf("6. LD4 done on, LD5 fault / LD7 link error off (led=%b)", led));

        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else            $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $finish;
    end
endmodule
