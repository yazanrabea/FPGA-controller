`timescale 1ns / 1ps
//==========================================================================
// sample_loopback_top_tb
//
// Verification plan 2026-11-01 Step 3: phase7_link_top with SAMPLER = 1
// (the core of sample_loopback_top.sv), end to end over the UART link (the
// sampler is the same behind either transport; 2 Mbaud keeps the run short).
// The mock PC loads config/phase7_seq_loopback.yaml's table (x1e-4, from
// phase7_link_tb_pkg, as phase7_link_top_tb), sets the sampler up over the
// link, runs the sequence and reads the record back with READ_REG.
//
// What is checked:
//   1. sampler info / defaults / config registers read back
//   2. a record triggered at the start of step 1 (EXT), 50 samples before:
//      status done / triggered, n_valid, trig_idx
//   3. every word read over the link = the cell's input on exactly the tick
//      samples.py says ((trig_count - trig_idx + i) * div + 1 after arming)
//   4. the cell's input = the pins 2 ticks earlier (outputs and inputs alike),
//      and with the jumpers in, bits 9:5 (inputs) = bits 4:0 (outputs)
//   5. the trigger sample is the first one at or after step 1's apply; rst
//      (bit 1) falls right after it and rises 5000 ticks later
//   6. the record is kept after the run (read twice, same); a new run with
//      trigger "now" re-arms it; a pulled jumper shows as bit 9 stuck at 0
// Pass = "ALL TESTS PASSED".
//==========================================================================
module sample_loopback_top_tb;

    localparam int BAUD = 2_000_000;      // 50 ticks per bit
    localparam int EB   = phase7_link_pkg::ENTRY_BYTES;
    localparam int UB   = phase7_link_pkg::USED_BYTES;
    localparam logic [15:0] SREG = 16'h0020, SBASE = 16'h4000;

    logic clk = 0;
    always #5 clk = ~clk;
    int unsigned cyc = 0;
    always @(posedge clk) cyc++;

    logic [7:0] led;
    wire  [31:0] fmc_pins;
    logic rxd, txd;
    logic [4:0] jumper = 5'b11111;

    phase7_link_top #(.BAUD(BAUD), .SAMPLER(1'b1)) dut (.clk(clk), .led(led), .fmc_pins(fmc_pins), .rxd(rxd), .txd(txd));

    genvar g;
    generate
        for (g = 0; g < 5; g = g + 1) begin : g_jumper
            assign fmc_pins[g + 16] = jumper[g] ? fmc_pins[g] : 1'b0;
        end
    endgenerate

    // ---- mock PC ----
    logic [7:0] pc_tx_data, pc_rx_data;
    logic pc_tx_send = 0, pc_tx_busy, pc_rx_valid, pc_rx_err;
    uart_tx #(.BAUD(BAUD)) u_pc_tx (.clk(clk), .rst_n(1'b1), .data_in(pc_tx_data), .send(pc_tx_send),
                                    .busy(pc_tx_busy), .tx(rxd));
    uart_rx #(.BAUD(BAUD)) u_pc_rx (.clk(clk), .rst_n(1'b1), .rx(txd), .data_out(pc_rx_data),
                                    .valid(pc_rx_valid), .frame_error(pc_rx_err));

    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask
    task automatic tick(input int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    function automatic logic [7:0] table_img(input int b);
        return phase7_link_tb_pkg::TABLE[b*8 +: 8];
    endfunction
    logic [7:0] fbuf [0:255];

    task automatic pc_send_byte(input logic [7:0] b);
        while (pc_tx_busy) tick(1);
        pc_tx_data = b; pc_tx_send = 1; tick(1); pc_tx_send = 0; tick(1);
    endtask
    task automatic pc_send_frame(input logic [7:0] cmd, input logic [15:0] addr, input int len);
        logic [7:0] ck;
        ck = cmd ^ addr[7:0] ^ addr[15:8] ^ 8'(len);
        pc_send_byte(8'hAA); pc_send_byte(cmd); pc_send_byte(addr[7:0]); pc_send_byte(addr[15:8]);
        pc_send_byte(8'(len));
        for (int i = 0; i < len; i++) begin ck = ck ^ fbuf[i]; pc_send_byte(fbuf[i]); end
        pc_send_byte(ck);
        while (pc_tx_busy) tick(1);
    endtask

    logic [7:0] resp [0:299];
    int resp_n;
    task automatic pc_recv(input int total);
        resp_n = 0;
        for (int i = 0; i < 400_000 && resp_n < total; i++) begin
            tick(1);
            if (pc_rx_valid) begin resp[resp_n] = pc_rx_data; resp_n++; end
        end
        if (resp_n < total) begin $display("  FAIL: timed out on a %0d-byte response (%0d)", total, resp_n); fails++; checks++; end
    endtask
    task automatic write_bytes(input logic [15:0] addr, input int len);
        pc_send_frame(8'h01, addr, len);
        tick(len + 10);
    endtask
    task automatic write_byte(input logic [15:0] addr, input logic [7:0] v);
        fbuf[0] = v; write_bytes(addr, 1);
    endtask
    task automatic read_bytes(input logic [15:0] addr, input int len);   // READ_REG; data at resp[5..]
        for (int i = 0; i < len; i++) fbuf[i] = 0;
        pc_send_frame(8'h02, addr, len);
        pc_recv(len + 6);
    endtask
    task automatic read_status(output logic [7:0] s);
        pc_send_frame(8'h07, 16'h0000, 0);
        pc_recv(7);
        s = resp[5];
    endtask
    task automatic wait_not_busy(output logic [7:0] s);
        s = 8'h02;
        for (int i = 0; i < 400 && s[1]; i++) begin tick(2000); read_status(s); end
    endtask
    function automatic int unsigned le(input int at, input int n);   // little-endian from resp[at..]
        int unsigned v = 0;
        for (int i = n - 1; i >= 0; i--) v = (v << 8) | resp[at + i];
        return v;
    endfunction

    // ---- sampler setup over the link ----
    task automatic sampler_setup(input int div, input int n, input int pre, input int trig,
                                 input int tpin, input int tstep);
        fbuf[0] = div[7:0]; fbuf[1] = div[15:8]; fbuf[2] = div[23:16]; fbuf[3] = div[31:24];
        fbuf[4] = n[7:0];   fbuf[5] = n[15:8];   fbuf[6] = pre[7:0];   fbuf[7] = pre[15:8];
        fbuf[8] = trig[7:0]; fbuf[9] = tpin[7:0]; fbuf[10] = tstep[7:0];
        write_bytes(SREG, 11);
    endtask

    int unsigned s_status, s_nvalid, s_tidx, s_tcount;
    task automatic sampler_status();
        read_bytes(SREG + 11, 9);
        s_status = resp[5]; s_nvalid = le(6, 2); s_tidx = le(8, 2); s_tcount = le(10, 4);
    endtask

    localparam int MAXW = 1024;
    logic [15:0] words [0:MAXW-1];
    task automatic read_record(input int n);     // n words, 100 per READ_REG (200 bytes)
        int done_w = 0, k;
        while (done_w < n) begin
            k = (n - done_w > 100) ? 100 : n - done_w;
            read_bytes(16'(SBASE + 2 * done_w), 2 * k);
            for (int i = 0; i < k; i++) words[done_w + i] = {resp[5 + 2*i + 1], resp[5 + 2*i]};
            done_w += k;
        end
    endtask

    // ---- monitors (negedge: registers settled). Arming = the posedge after run rises
    //      at the cell; sample k holds s_in as seen at negedge (arm_n + 1 + k*div). ----
    localparam int HMAX = 200_000;
    logic [15:0] h_sin  [0:HMAX-1];   // the cell's input, per tick from run rising
    logic [9:0]  h_pins [0:HMAX-1];   // {inputs 20:16, outputs 4:0}
    int unsigned arm_n, step_start_n [0:15], step_at_start [0:15];
    int n_starts;
    logic run_q = 0;
    int rel;
    always @(negedge clk) begin
        if (dut.run && !run_q) begin arm_n = cyc; n_starts = 0; end
        run_q = dut.run;
        rel = cyc - arm_n;
        if (dut.run && rel < HMAX) begin
            h_sin[rel]  = dut.g_sampler.s_in;
            h_pins[rel] = {fmc_pins[20:16], fmc_pins[4:0]};
        end
        if (dut.step_start) begin step_start_n[n_starts] = cyc - arm_n; step_at_start[n_starts] = dut.step; n_starts++; end
    end

    initial begin #(300ms); $display("FAIL: watchdog"); $finish; end

    int bad, fall_i, rise_i, first_bad, tsample, div, s1;
    logic [7:0] s;
    logic [15:0] keep [0:MAXW-1];

    initial begin
        tick(50);

        $display("\n== 1. load the table; sampler info, defaults, config ==");
        for (int k = 0; k < phase7_link_tb_pkg::N_STEPS; k++) begin
            for (int i = 0; i < UB; i++) fbuf[i] = table_img(k*EB + i);
            write_bytes(16'(phase7_link_pkg::TABLE_BASE + k*EB), UB);
        end
        write_byte(phase7_link_pkg::REG_N_STEPS, 8'(phase7_link_tb_pkg::N_STEPS));
        pc_send_frame(8'h04, 16'h0000, 0);   // APPLY: idle state
        tick(200);
        read_bytes(SREG, 24);
        check(resp[5 + 20] == 8'd16 && resp[5 + 21] == 8'd12, $sformatf("INFO: 16 bits/sample, 2^%0d samples", resp[5 + 21]));
        check(le(5, 4) == 1 && le(9, 2) == 4096 && le(11, 2) == 0 && resp[5 + 8] == 0,
              "defaults: div 1, n 4096, pre 0, trigger now");
        div = 20;
        sampler_setup(div, 400, 50, 1, 0, 1);    // EXT = the start of step 1
        read_bytes(SREG, 11);
        check(le(5, 4) == 20 && le(9, 2) == 400 && le(11, 2) == 50 && resp[13] == 1 && resp[15] == 1,
              "config written and read back (div 20, n 400, pre 50, ext at step 1)");
        sampler_status();
        check(s_status == 0, "nothing armed before RUN");

        $display("\n== 2. RUN: record around the start of step 1 ==");
        pc_send_frame(8'h05, 16'h0000, 0);
        wait_not_busy(s);
        check(s[2] && !s[3], $sformatf("sequence done (%b)", s));
        sampler_status();
        check(s_status == 3'b110, $sformatf("sampler: triggered + done, not armed (%b)", s_status));
        check(s_nvalid == 400 && s_tidx == 50, $sformatf("400 samples, trigger at index 50 (%0d, %0d)", s_nvalid, s_tidx));
        // step 0's step_start comes one cycle before run rises (so before this monitor's
        // reset); the entries here are steps 1, 2, ...: find step 1's
        s1 = -1;
        for (int k = 0; k < n_starts; k++) if (step_at_start[k] == 1 && s1 < 0) s1 = k;
        check(s1 == 0 && n_starts == phase7_link_tb_pkg::N_STEPS - 1,
              $sformatf("step_start: steps 1..%0d seen after run rose, step = the new step on its cycle (what trig_ext uses)",
                        n_starts));

        $display("\n== 3. the record read over the link, against the cell's input ==");
        read_record(400);
        bad = 0; first_bad = -1;
        for (int i = 0; i < 400; i++)
            if (words[i] !== h_sin[1 + (s_tcount - s_tidx + i) * div]) begin
                bad++; if (first_bad < 0) first_bad = i;
            end
        check(bad == 0, $sformatf("all 400 words = s_in at (trig_count - trig_idx + i)*div + 1 (%0d wrong, first %0d)", bad, first_bad));

        $display("\n== 4. alignment of outputs and inputs ==");
        bad = 0;
        for (int t = 3; t < (s_tcount + 360) * div; t++)
            if (h_sin[t][9:0] !== h_pins[t - 2]) bad++;
        check(bad == 0, $sformatf("s_in = the pins 2 ticks earlier, every tick of the record (%0d off)", bad));
        bad = 0;
        for (int i = 0; i < 400; i++) if (words[i][9:5] !== words[i][4:0] || words[i][15:10] != 0) bad++;
        check(bad == 0, "jumpers in: inputs (bits 9:5) = outputs (bits 4:0) in every sample, bits 15:10 = 0");

        $display("\n== 5. the trigger and the rst pulse in the record ==");
        tsample = 1 + s_tcount * div;                  // tick of the trigger sample after arming
        check(tsample >= step_start_n[s1] && tsample - div < step_start_n[s1],
              $sformatf("trigger sample (tick %0d) is the first at/after step 1's apply (tick %0d)", tsample, step_start_n[s1]));
        fall_i = -1; rise_i = -1;
        for (int i = 1; i < 400; i++) begin
            if (words[i - 1][1] && !words[i][1] && fall_i < 0) fall_i = i;
            if (!words[i - 1][1] && words[i][1] && fall_i >= 0 && rise_i < 0) rise_i = i;
        end
        check(fall_i == 50 || fall_i == 51, $sformatf("rst falls at the trigger (index %0d)", fall_i));
        check(rise_i - fall_i == 250, $sformatf("rst low for 250 samples = 5000 ticks (%0d)", rise_i - fall_i));

        $display("\n== 6. kept after the run; re-arm; a pulled jumper ==");
        for (int i = 0; i < 400; i++) keep[i] = words[i];
        tick(5000);
        read_record(400);
        bad = 0;
        for (int i = 0; i < 400; i++) if (words[i] !== keep[i]) bad++;
        check(bad == 0, "read again after the run: the same record");
        jumper[1] = 1'b0;                              // rst_in pulled (no FAULT: nothing waits on it)
        sampler_setup(5, 100, 0, 0, 0, 0);             // trigger now, 100 samples every 5 ticks
        pc_send_frame(8'h05, 16'h0000, 0);
        wait_not_busy(s);
        sampler_status();
        check(s_status == 3'b110 && s_nvalid == 100 && s_tidx == 0 && s_tcount == 0,
              $sformatf("new run, trigger now: 100 samples from the first (%b %0d %0d %0d)", s_status, s_nvalid, s_tidx, s_tcount));
        read_record(100);
        bad = 0;
        for (int i = 0; i < 100; i++) if (words[i][6] !== 1'b0 || words[i] !== h_sin[1 + i * 5]) bad++;
        check(bad == 0, "re-armed record: rst_in (bit 6) stuck at 0 with the jumper pulled, words = s_in");
        check(words[0][1] == 1'b1, "rst output itself still high in step 0 (bit 1)");
        jumper[1] = 1'b1;
        check(!led[7], "no link error (LD7 off)");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
