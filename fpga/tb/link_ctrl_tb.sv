`timescale 1ns / 1ps
//==========================================================================
// link_ctrl_tb — self-checking testbench for link_ctrl.sv (Phase 5).
//
// Feeds rx_byte/rx_byte_valid directly (link_ctrl's own byte-level
// interface, same shape uart_rx.sv produces) rather than real UART bit
// timing -- that plumbing is uart_tb.sv's job, already passing on its own.
// A small mock responder stands in for uart_tx.sv: asserts tx_busy for a
// few cycles after each tx_send, and records every sent byte, so response
// frames can be checked without needing real UART timing either.
//==========================================================================
module link_ctrl_tb;

    localparam int N_SIG = 5;
    localparam int N_CAP = 5;

    logic clk = 0;
    logic rst_n;

    logic [7:0] rx_byte;
    logic        rx_byte_valid;
    logic [7:0] tx_byte;
    logic        tx_send;
    logic        tx_busy;

    logic run_set, run_clear, apply_cmd, run;

    logic [2:0]  sig_cfg_type[N_SIG];
    logic         sig_cfg_idle_level[N_SIG];
    logic         sig_cfg_msb_first[N_SIG];
    logic [31:0] sig_cfg_delay[N_SIG];
    logic [31:0] sig_cfg_param_a[N_SIG];
    logic [31:0] sig_cfg_param_b[N_SIG];
    logic [31:0] sig_cfg_cycles[N_SIG];
    logic [15:0] sig_cfg_data[N_SIG];
    logic [31:0] sig_cfg_bits[N_SIG];

    logic [1:0]  cap_cfg_mode[N_CAP];
    logic         cap_cfg_msb_first[N_CAP];
    logic [31:0] cap_cfg_bits[N_CAP];

    logic         cap_level_out[N_CAP];
    logic         cap_period_valid[N_CAP];
    logic         cap_done[N_CAP];
    logic [31:0] cap_edge_count[N_CAP];
    logic [31:0] cap_period_ticks[N_CAP];
    logic [31:0] cap_high_ticks[N_CAP];
    logic [15:0] cap_capture_reg[N_CAP];

    link_ctrl #(.N_SIG(N_SIG), .N_CAP(N_CAP)) dut (.*);

    always #5 clk = ~clk;

    // ---- mock uart_tx: busy for 3 cycles per byte, records every sent byte ----
    logic [7:0] resp_bytes[0:255];
    int          resp_count;
    int          mock_busy_cnt;
    // Plain `always`, not always_ff: resp_count is also cleared by the tasks below, and
    // IEEE 1800 forbids a second driver on an always_ff variable (xsim VRFC 10-3818;
    // Icarus silently allows it). Testbench-only mock, so this costs nothing.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy <= 1'b0;
            mock_busy_cnt <= 0;
        end else if (tx_send) begin
            resp_bytes[resp_count] <= tx_byte;
            resp_count <= resp_count + 1;
            tx_busy <= 1'b1;
            mock_busy_cnt <= 3;
        end else if (mock_busy_cnt > 0) begin
            mock_busy_cnt <= mock_busy_cnt - 1;
            if (mock_busy_cnt == 1) tx_busy <= 1'b0;
        end
    end

    int fails = 0, checks = 0;
    task automatic check(logic cond, string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    task automatic tick(int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    // one reusable module-level scratch buffer for every test's frame payload --
    // declared here (before send_frame, which reads it) because Icarus 13.0 requires
    // declaration-before-use even for module-level items referenced inside a task.
    logic [7:0] fbuf[16];
    task automatic clear_fbuf();
        for (int i = 0; i < 16; i++) fbuf[i] = 8'h00;
    endtask

    // Reads its payload from the module-level `fbuf` directly instead of taking a
    // `data[]` argument -- Icarus 13.0 doesn't properly support passing unpacked arrays
    // as task arguments at all (confirmed: fails even with a fixed-size formal matched
    // to a fixed-size actual, with the same "needs an array index" elaboration error).
    // Callers: clear_fbuf() + set the bytes you need in fbuf[], then call this.
    task automatic send_frame(logic [7:0] cmd, logic [15:0] addr, int len);
        logic [7:0] cksum;
        @(negedge clk); rx_byte = 8'hAA; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        cksum = cmd;
        @(negedge clk); rx_byte = cmd; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        cksum = cksum ^ addr[7:0];
        @(negedge clk); rx_byte = addr[7:0]; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        cksum = cksum ^ addr[15:8];
        @(negedge clk); rx_byte = addr[15:8]; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        cksum = cksum ^ len[7:0];
        @(negedge clk); rx_byte = len[7:0]; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        for (int i = 0; i < len; i++) begin
            cksum = cksum ^ fbuf[i];
            @(negedge clk); rx_byte = fbuf[i]; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        end
        @(negedge clk); rx_byte = cksum; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
    endtask

    task automatic send_frame_bad_checksum(logic [7:0] cmd, logic [15:0] addr);
        @(negedge clk); rx_byte = 8'hAA; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        @(negedge clk); rx_byte = cmd; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        @(negedge clk); rx_byte = addr[7:0]; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        @(negedge clk); rx_byte = addr[15:8]; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        @(negedge clk); rx_byte = 8'h00; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);
        @(negedge clk); rx_byte = 8'hFF; rx_byte_valid = 1; @(negedge clk); rx_byte_valid = 0; tick(1);  // deliberately wrong
    endtask

    task automatic wait_for_response(int expected_total_bytes);
        resp_count = 0;
        for (int i = 0; i < 20000; i++) begin
            tick(1);
            if (resp_count >= expected_total_bytes) return;
        end
        $display("  FAIL: timed out waiting for a %0d-byte response (got %0d bytes)", expected_total_bytes, resp_count);
        fails++; checks++;
    endtask

    task automatic reset_dut();
        rst_n = 0; rx_byte = 0; rx_byte_valid = 0; run = 0;
        for (int i = 0; i < N_CAP; i++) begin
            cap_level_out[i] = 0; cap_period_valid[i] = 0; cap_done[i] = 0;
            cap_edge_count[i] = 0; cap_period_ticks[i] = 0; cap_high_ticks[i] = 0; cap_capture_reg[i] = 0;
        end
        tick(3);
        @(negedge clk); rst_n = 1;
        tick(3);
    endtask

    initial begin
        reset_dut();

        // ---- 1. echo: write SCRATCH, read it back ----
        $display("\n-- echo (SCRATCH write/readback) --");
        clear_fbuf(); fbuf[0] = 8'h42;
        send_frame(8'h01 /*WRITE_REG*/, 16'h0000, 1);
        resp_count = 0;
        clear_fbuf();
        send_frame(8'h02 /*READ_REG*/, 16'h0000, 1);
        wait_for_response(7);  // SOF+CMD+ADDR_LO+ADDR_HI+LEN+1 data+CKSUM
        check(resp_bytes[0] == 8'hAA, "response SOF correct");
        check(resp_bytes[1] == 8'h02, "response CMD echoes READ_REG");
        check(resp_bytes[5] == 8'h42, "readback matches what was written to SCRATCH");

        // ---- 2. write test_clock's (cell 0) PARAM_A, read it back, check the live port ----
        $display("\n-- sig_cell PARAM_A write + readback + live port --");
        clear_fbuf();
        fbuf[0] = 8'h78; fbuf[1] = 8'h56; fbuf[2] = 8'h34; fbuf[3] = 8'h12;  // 0x12345678 LE
        send_frame(8'h01, 16'h0010 + 5, 4);
        tick(2);
        check(sig_cfg_param_a[0] == 32'h12345678, $sformatf("sig_cfg_param_a[0]=0x%08h", sig_cfg_param_a[0]));
        clear_fbuf();
        send_frame(8'h02, 16'h0010 + 5, 4);
        wait_for_response(10);
        check({resp_bytes[8], resp_bytes[7], resp_bytes[6], resp_bytes[5]} == 32'h12345678,
              "READ_REG readback matches the written PARAM_A");

        // ---- 3. CTRL byte: type/idle/msb_first ----
        $display("\n-- sig_cell CTRL byte --");
        // type=CLOCK(3)=3'b011, idle_level=0, msb_first=1 -> bits: msb(4)=1,idle(3)=0,type[2:0]=011 -> 8'b0001_0011
        clear_fbuf(); fbuf[0] = 8'b0001_0011;
        send_frame(8'h01, 16'h0010, 1);
        tick(2);
        check(sig_cfg_type[0] == 3'd3, "cfg_type decoded as CLOCK");
        check(sig_cfg_idle_level[0] == 1'b0, "cfg_idle_level decoded as 0");
        check(sig_cfg_msb_first[0] == 1'b1, "cfg_msb_first decoded as 1");

        // ---- 4. RUN / STOP / APPLY pulses ----
        $display("\n-- RUN / STOP / APPLY --");
        begin
            // send_frame's own last tick() already lands exactly on the DISPATCH cycle
            // that pulses these one-cycle signals, so check immediately on return (not
            // after an extra tick first) -- same class of bug Phase 3 hit: checking a
            // transient pulse one cycle too late, after it already came and went.
            logic saw;
            clear_fbuf();
            send_frame(8'h05 /*RUN*/, 16'h0000, 0);
            saw = run_set; for (int i = 0; i < 10 && !saw; i++) begin tick(1); if (run_set) saw = 1'b1; end
            check(saw, "RUN command pulsed run_set");

            send_frame(8'h06 /*STOP*/, 16'h0000, 0);
            saw = run_clear; for (int i = 0; i < 10 && !saw; i++) begin tick(1); if (run_clear) saw = 1'b1; end
            check(saw, "STOP command pulsed run_clear");

            send_frame(8'h04 /*APPLY*/, 16'h0000, 0);
            saw = apply_cmd; for (int i = 0; i < 10 && !saw; i++) begin tick(1); if (apply_cmd) saw = 1'b1; end
            check(saw, "APPLY command pulsed apply_cmd");
        end

        // ---- 5. STATUS reflects the live `run` input ----
        $display("\n-- STATUS --");
        run = 1'b1;
        send_frame(8'h07 /*STATUS*/, 16'h0000, 0);
        wait_for_response(7);
        check(resp_bytes[1] == 8'h07, "response CMD echoes STATUS");
        check(resp_bytes[5][0] == 1'b1, "STATUS bit0 reflects run=1");
        run = 1'b0;

        // ---- 6. READ_CAPTURE reads cap_cell k's live status/results ----
        // cell 1's block starts at offset 24 within the cap region; +0..+4 is its
        // writable CTRL/BITS, so STATUS_FLAGS (the first read-only byte) is at +5.
        $display("\n-- READ_CAPTURE --");
        clear_fbuf();
        cap_level_out[1]   = 1'b1;
        cap_edge_count[1]  = 32'h12345678;
        send_frame(8'h08 /*READ_CAPTURE*/, 16'd29 /* cell 1's STATUS_FLAGS offset: 24+5 */, 5);
        wait_for_response(11);  // 6 header/footer bytes + 5 data (STATUS_FLAGS + 4 EDGE_COUNT bytes)
        check(resp_bytes[1] == 8'h08, "response CMD echoes READ_CAPTURE");
        check(resp_bytes[5][0] == 1'b1, "STATUS_FLAGS bit0 = cap_level_out[1]");
        check({resp_bytes[9], resp_bytes[8], resp_bytes[7], resp_bytes[6]} == 32'h12345678,
              "EDGE_COUNT matches cap_edge_count[1]");
        cap_level_out[1] = 1'b0;
        cap_edge_count[1] = 32'h0;

        // ---- 7. cap_cell shadow config (CTRL + BITS) ----
        $display("\n-- cap_cell shadow config --");
        // mode=PERIOD(2)=2'b10, msb_first=1 -> bits: msb(2)=1, mode[1:0]=10 -> 8'b0000_0110
        clear_fbuf(); fbuf[0] = 8'b0000_0110;
        send_frame(8'h01, 16'h0100 + 24 * 2 /* cell 2 */, 1);
        tick(2);
        check(cap_cfg_mode[2] == 2'd2, "cap_cfg_mode[2] decoded as PERIOD");
        check(cap_cfg_msb_first[2] == 1'b1, "cap_cfg_msb_first[2] decoded as 1");

        // ---- 8. bad checksum -> NACK ----
        $display("\n-- bad checksum -> NACK --");
        send_frame_bad_checksum(8'h07, 16'h0000);
        wait_for_response(6);  // SOF+CMD+ADDR_LO+ADDR_HI+LEN(0)+CKSUM, no data
        check(resp_bytes[1] == 8'hFF, "NACK returned for a bad checksum");
        check(resp_bytes[4] == 8'h00, "NACK's LEN is 0");

        // ---- 9. LOAD_MODE (unimplemented) -> NACK ----
        $display("\n-- LOAD_MODE -> NACK (unimplemented, not silently ignored) --");
        clear_fbuf();
        send_frame(8'h03 /*LOAD_MODE*/, 16'h0000, 0);
        wait_for_response(6);
        check(resp_bytes[1] == 8'hFF, "NACK returned for LOAD_MODE");

        // ---- 10. unknown CMD -> NACK ----
        $display("\n-- unknown CMD -> NACK --");
        clear_fbuf();
        send_frame(8'h99, 16'h0000, 0);
        wait_for_response(6);
        check(resp_bytes[1] == 8'hFF, "NACK returned for an unknown CMD");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
