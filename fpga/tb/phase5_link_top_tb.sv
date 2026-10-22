`timescale 1ns / 1ps
//==========================================================================
// phase5_link_top_tb
//
// Real end-to-end test: a mock "PC" (its own uart_tx/uart_rx pair, cross-
// wired to the DUT's txd/rxd) sends actual bit-serial UART frames in and
// reads real bit-serial responses back -- not the byte-level shortcut
// link_ctrl_tb.sv uses. Models the 5 external jumper wires the same way
// phase4_loopback_top_tb.sv does (shorting fmc_pins[i] to fmc_pins[i+16]),
// since those don't exist inside the DUT either.
//
// Centerpiece: configures test_clock via the link, RUNs it, measures its
// period on the loopback pin, then -- WHILE STILL RUNNING -- writes a new
// frequency and re-measures, directly exercising Phase 5's own exit
// criterion ("change a clock frequency from the PC without re-synthesis
// and see it ... "): [simulated] here; the real "...and see it on the
// multimeter/scope" still needs actual hardware (docs/experiments/EXP-02).
//==========================================================================
module phase5_link_top_tb;

    logic clk = 0;
    logic [2:0] sw = 3'd0;
    logic [7:0] led;
    wire  [31:0] fmc_pins;
    logic rxd, txd;

    phase5_link_top dut (.clk(clk), .sw(sw), .led(led), .fmc_pins(fmc_pins), .rxd(rxd), .txd(txd));

    // the 5 external jumper wires
    genvar g;
    generate
        for (g = 0; g < 5; g = g + 1) begin : g_jumper
            assign fmc_pins[g + 16] = fmc_pins[g];
        end
    endgenerate

    // ---- mock PC: its own UART pair, cross-wired to the DUT ----
    logic rst_n_tb;  // not a DUT reset -- just for the mock PC's own UART pair
    assign rst_n_tb = 1'b1;

    logic [7:0] pc_tx_data;
    logic        pc_tx_send, pc_tx_busy;
    logic [7:0] pc_rx_data;
    logic        pc_rx_valid, pc_rx_frame_error;

    uart_tx #(.CLK_FREQ_HZ(100_000_000), .BAUD(115_200)) u_pc_tx (
        .clk(clk), .rst_n(rst_n_tb),
        .data_in(pc_tx_data), .send(pc_tx_send), .busy(pc_tx_busy),
        .tx(rxd)  // PC's TX -> DUT's RX
    );
    uart_rx #(.CLK_FREQ_HZ(100_000_000), .BAUD(115_200)) u_pc_rx (
        .clk(clk), .rst_n(rst_n_tb),
        .rx(txd),  // DUT's TX -> PC's RX
        .data_out(pc_rx_data), .valid(pc_rx_valid), .frame_error(pc_rx_frame_error)
    );

    always #5 clk = ~clk;  // 100 MHz

    int fails = 0, checks = 0;
    task automatic check(logic cond, string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    task automatic tick(int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    task automatic pc_send_byte(logic [7:0] b);
        while (pc_tx_busy) tick(1);
        @(negedge clk); pc_tx_data = b; pc_tx_send = 1;
        @(negedge clk); pc_tx_send = 0;
    endtask

    logic [7:0] fbuf[16];
    task automatic clear_fbuf();
        for (int i = 0; i < 16; i++) fbuf[i] = 8'h00;
    endtask

    // one UART byte (start + 8 data + stop) takes this many clk cycles at
    // 100 MHz / 115200 baud -- used to size the margin after a frame send.
    localparam int BYTE_CYCLES = (100_000_000 / 115_200) * 10;

    task automatic pc_send_frame(logic [7:0] cmd, logic [15:0] addr, int len);
        logic [7:0] cksum;
        cksum = cmd ^ addr[7:0] ^ addr[15:8] ^ len[7:0];
        for (int i = 0; i < len; i++) cksum = cksum ^ fbuf[i];
        pc_send_byte(8'hAA);
        pc_send_byte(cmd);
        pc_send_byte(addr[7:0]);
        pc_send_byte(addr[15:8]);
        pc_send_byte(len[7:0]);
        for (int i = 0; i < len; i++) pc_send_byte(fbuf[i]);
        pc_send_byte(cksum);
        // pc_send_byte only waits for busy BEFORE queuing a new byte, so it
        // returns as soon as the checksum's send pulse is latched -- the
        // checksum itself is still being shifted out bit by bit. Wait for
        // that last byte to actually finish on the wire before returning.
        // Deliberately NOT adding extra margin here for the DUT to receive
        // and dispatch it: for commands with a response, the response can
        // start arriving within that margin and pc_wait_for_response (which
        // starts listening immediately, before any margin) would then miss
        // its leading byte(s). Callers that need to observe a side effect of
        // a response-less command (RUN/STOP/APPLY) add their own margin.
        while (pc_tx_busy) tick(1);
    endtask

    logic [7:0] resp_bytes[0:31];
    int          resp_count;
    task automatic pc_wait_for_response(int expected_total_bytes);
        // loop flag instead of `return` inside the task: Icarus 12 rejects return in tasks
        resp_count = 0;
        for (int i = 0; i < 400_000 && resp_count < expected_total_bytes; i++) begin
            tick(1);
            if (pc_rx_valid) begin
                resp_bytes[resp_count] = pc_rx_data;
                resp_count = resp_count + 1;
            end
        end
        if (resp_count < expected_total_bytes) begin
            $display("  FAIL: timed out waiting for a %0d-byte response (got %0d bytes)", expected_total_bytes, resp_count);
            fails++; checks++;
        end
    endtask

    // measure the period of a loopback pin in ticks, by watching fmc_pins directly
    task automatic measure_period_ticks(int pin_idx, output int period_ticks, input int max_ticks);
        int t_rise1, t_rise2;
        logic prev;
        // loop flag instead of `return` inside the task: Icarus 12 rejects return in tasks
        t_rise1 = -1; t_rise2 = -1;
        prev = fmc_pins[pin_idx];
        period_ticks = -1;
        for (int i = 0; i < max_ticks && t_rise2 < 0; i++) begin
            tick(1);
            if (fmc_pins[pin_idx] && !prev) begin
                if (t_rise1 < 0) t_rise1 = i;
                else begin t_rise2 = i; period_ticks = t_rise2 - t_rise1; end
            end
            prev = fmc_pins[pin_idx];
        end
    endtask

    initial begin
        pc_tx_data = 0; pc_tx_send = 0;
        tick(20);  // let the DUT's power-on reset settle

        // ---- 1. configure test_clock (cell 0): type=CLOCK, period=20 ticks, high=10 ----
        $display("\n-- configure test_clock via the link --");
        clear_fbuf();
        fbuf[0] = 8'b0000_0011;  // CTRL: type=CLOCK(3), idle=0, msb_first=0
        pc_send_frame(8'h01 /*WRITE_REG*/, 16'h0010, 1);
        clear_fbuf();
        fbuf[0] = 20; fbuf[1] = 0; fbuf[2] = 0; fbuf[3] = 0;  // PARAM_A (period) = 20 ticks, LE
        pc_send_frame(8'h01, 16'h0010 + 5, 4);
        clear_fbuf();
        fbuf[0] = 10; fbuf[1] = 0; fbuf[2] = 0; fbuf[3] = 0;  // PARAM_B (high) = 10 ticks, LE
        pc_send_frame(8'h01, 16'h0010 + 9, 4);

        // readback check before APPLY/RUN
        clear_fbuf();
        pc_send_frame(8'h02 /*READ_REG*/, 16'h0010 + 5, 4);
        pc_wait_for_response(10);
        check({resp_bytes[8], resp_bytes[7], resp_bytes[6], resp_bytes[5]} == 32'd20,
              "PARAM_A readback = 20 before APPLY");

        // ---- 2. APPLY, then RUN ----
        $display("\n-- APPLY + RUN --");
        clear_fbuf();
        pc_send_frame(8'h04 /*APPLY*/, 16'h0000, 0);
        tick(BYTE_CYCLES);  // margin for the DUT to receive + dispatch (no response to wait on)
        clear_fbuf();
        pc_send_frame(8'h05 /*RUN*/, 16'h0000, 0);
        tick(BYTE_CYCLES);
        check(led[4] == 1'b1, "RUN LED is on after the RUN command");

        // ---- 3. measure the period on the loopback pin: should be 20 ticks ----
        $display("\n-- measure period (expect 20 ticks) --");
        begin
            int period;
            measure_period_ticks(0, period, 2000);
            check(period == 20, $sformatf("measured period = %0d ticks (expected 20)", period));
        end

        // ---- 4. change the frequency WHILE RUNNING (the actual exit criterion) ----
        $display("\n-- change frequency while running --");
        clear_fbuf();
        fbuf[0] = 40; fbuf[1] = 0; fbuf[2] = 0; fbuf[3] = 0;  // new PARAM_A = 40 ticks
        pc_send_frame(8'h01, 16'h0010 + 5, 4);
        clear_fbuf();
        fbuf[0] = 20; fbuf[1] = 0; fbuf[2] = 0; fbuf[3] = 0;  // new PARAM_B = 20 ticks (keep 50% duty)
        pc_send_frame(8'h01, 16'h0010 + 9, 4);
        clear_fbuf();
        pc_send_frame(8'h04 /*APPLY*/, 16'h0000, 0);  // still RUNning the whole time
        tick(BYTE_CYCLES);
        begin
            int period;
            measure_period_ticks(0, period, 2000);
            check(period == 40, $sformatf("after a live APPLY, measured period = %0d ticks (expected 40)", period));
        end
        check(led[4] == 1'b1, "still RUNning the entire time -- never stopped to reconfigure");

        // ---- 5. STOP, confirm the pin returns to idle ----
        $display("\n-- STOP --");
        clear_fbuf();
        pc_send_frame(8'h06 /*STOP*/, 16'h0000, 0);
        tick(BYTE_CYCLES);
        check(led[4] == 1'b0, "RUN LED off after STOP");
        check(fmc_pins[0] == 1'b0, "test_clock pin idle (0) after STOP");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
