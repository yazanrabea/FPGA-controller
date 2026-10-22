`timescale 1ns / 1ps
//==========================================================================
// uart_tb — self-checking testbench for uart_tx.sv + uart_rx.sv (Phase 5).
// Real default parameters (100 MHz / 115200 baud), not a scaled-down fast
// test config -- a full byte takes ~8700 clk cycles, which iverilog runs
// through in well under a second, so there's no need to fake the timing.
//==========================================================================
module uart_tb;

    localparam int CLK_FREQ_HZ = 100_000_000;
    localparam int BAUD        = 115_200;

    logic clk = 0;
    logic rst_n;

    logic [7:0] tx_data;
    logic       tx_send;
    logic       tx_busy;
    logic       tx_line;

    uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data_in(tx_data), .send(tx_send), .busy(tx_busy),
        .tx(tx_line)
    );

    logic [7:0] rx_data;
    logic       rx_valid, rx_frame_error;

    uart_rx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx(tx_line),  // direct loopback: tx's own line feeds rx
        .data_out(rx_data), .valid(rx_valid), .frame_error(rx_frame_error)
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

    task automatic send_byte(logic [7:0] b);
        @(negedge clk);
        tx_data = b;
        tx_send = 1;
        @(negedge clk);
        tx_send = 0;
    endtask

    task automatic wait_for_rx_byte(output logic [7:0] got, output logic got_err);
        // loop flag instead of `return` inside the task: Icarus 12 rejects return in tasks
        logic found;
        got = 8'h00; got_err = 1'b0; found = 1'b0;
        for (int i = 0; i < 20000 && !found; i++) begin
            tick(1);
            if (rx_valid) begin
                got = rx_data;
                got_err = rx_frame_error;
                found = 1'b1;
            end
        end
        if (!found) begin
            $display("  FAIL: timed out waiting for a received byte");
            fails++;
            checks++;
        end
    endtask

    initial begin
        rst_n = 0; tx_data = 0; tx_send = 0;
        tick(5);
        @(negedge clk); rst_n = 1;
        tick(5);

        // ---- 1. single byte round trip ----
        $display("\n-- single byte round trip --");
        send_byte(8'hA5);
        begin
            logic [7:0] got; logic err;
            wait_for_rx_byte(got, err);
            check(got == 8'hA5, $sformatf("received 0x%02h (expected 0xA5)", got));
            check(err == 1'b0, "no frame error on a clean byte");
        end

        // ---- 2. busy is asserted during the send, clears after ----
        // (rx_valid fires roughly half a bit period before tx_busy actually drops --
        // RX samples at bit MIDDLES, TX keeps driving the stop bit to its full end --
        // so always wait for tx_busy to clear before issuing the next send.)
        $display("\n-- busy flag --");
        while (tx_busy) tick(1);
        @(negedge clk);
        tx_data = 8'h3C;
        tx_send = 1;
        @(negedge clk);
        tx_send = 0;
        check(tx_busy == 1'b1, "busy is high right after starting a send");
        begin
            logic [7:0] got; logic err;
            wait_for_rx_byte(got, err);
            check(got == 8'h3C, $sformatf("received 0x%02h (expected 0x3C)", got));
        end
        tick(500);  // rx_valid fires before tx_busy actually clears (see note above); margin > HALF_DIV
        check(tx_busy == 1'b0, "busy drops once the stop bit has gone out");

        // ---- 3. several distinct bytes back to back ----
        $display("\n-- several bytes back to back --");
        begin
            // element by element: Icarus 12 doesn't support a whole-array initializer here
            logic [7:0] pattern[4];
            logic [7:0] got; logic err;
            pattern[0] = 8'h00; pattern[1] = 8'hFF; pattern[2] = 8'h55; pattern[3] = 8'hAA;
            for (int i = 0; i < 4; i++) begin
                while (tx_busy) tick(1);
                send_byte(pattern[i]);
                wait_for_rx_byte(got, err);
                check(got == pattern[i], $sformatf("byte %0d: received 0x%02h (expected 0x%02h)", i, got, pattern[i]));
            end
        end

        // ---- 4. a send while busy is ignored, not queued or corrupted ----
        $display("\n-- send while busy is ignored --");
        while (tx_busy) tick(1);
        begin
            logic [7:0] got; logic err;
            send_byte(8'h11);
            tick(3);  // still mid-frame (a full byte is ~8700 cycles)
            send_byte(8'h99);  // should be ignored: tx_busy is still 1
            wait_for_rx_byte(got, err);
            check(got == 8'h11, $sformatf("got the FIRST byte (0x%02h), the ignored second send didn't corrupt it", got));
        end

        // ---- 5. a bad stop bit is flagged as a frame error ----
        // Drive rx directly (bypassing uart_tx) with a hand-built frame whose
        // stop bit is 0 instead of 1.
        $display("\n-- bad stop bit -> frame_error --");
        while (tx_busy) tick(1);
        begin
            localparam int BAUD_DIV = CLK_FREQ_HZ / BAUD;
            logic [7:0] got; logic err;
            force u_rx.rx = 1'b1; tick(20);  // long settle before the hand-built frame
            force u_rx.rx = 1'b0; tick(BAUD_DIV);           // start bit
            for (int i = 0; i < 8; i++) begin
                force u_rx.rx = 1'b1; tick(BAUD_DIV);        // 8 data bits, all 1s
            end
            // stop bit WRONG (should be 1) -- the valid/frame_error pulse fires partway
            // through this bit's window (RX samples at bit MIDDLES), so start polling
            // for it immediately instead of blind-ticking through the whole window
            // first: `tick()` doesn't check rx_valid, and it's only a 1-cycle pulse, so
            // ticking blindly past it here would miss it entirely (found exactly that
            // bug first -- the fix is this reordering, not a timing-margin tweak).
            force u_rx.rx = 1'b0;
            wait_for_rx_byte(got, err);
            release u_rx.rx;
            force u_rx.rx = 1'b1;  // line idles high again afterward
            check(got == 8'hFF, $sformatf("data bits still decoded correctly (0x%02h)", got));
            check(err == 1'b1, "frame_error flagged for the bad stop bit");
            release u_rx.rx;
        end

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
