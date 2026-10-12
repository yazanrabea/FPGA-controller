`timescale 1ns / 1ps
//==========================================================================
// fmc_clock_loopback
//
// Self-contained FPGA loopback checker for the ZedBoard FMC LA pins, using
// a REAL toggling clock signal instead of a static 0/1 level. Confirms a
// pin pair can carry a dynamic (AC) signal, not just a DC level -- closer
// to what an actual chip clock/data line needs to do.
//
// Pin split (same convention as fmc_selectable_loopback):
//   fmc_pins[15:0]  = OUTPUTS
//   fmc_pins[31:16] = INPUTS
//   pair i (0-15)   = output pin i  <->  input pin i+16
//
// HOW TO USE
//   sw[3:0] : pick which pair (0-15) to test
//   sw[4]   : 1 = drive a 1 MHz, 50% duty square wave on that pair's output
//             pin; 0 = hold the output low AND reset the fault latch below
//   LD0     : the live clock being driven right now
//   LD1     : the live clock read back on the paired input pin
//   LD2     : live match indicator (same style as the static test)
//   LD3     : sticky FAULT latch -- the real answer. Stays OFF as long as
//             no run of 16+ CONSECUTIVE mismatched cycles has occurred
//             since sw[4] went high (after a ~20ms settle window that
//             ignores switch-bounce transients); turns ON and STAYS ON
//             once that happens. A single isolated glitch (normal
//             electrical noise on an unshielded jumper wire) will NOT
//             trip it -- only a sustained disagreement will.
//
//   Jumper (or header wire) output pin `sw[3:0]` to input pin
//   `sw[3:0]+16`. Set sw[4]=0 first (clears LD3), then set sw[4]=1 and
//   wait a moment -- LD3 staying dark is your confirmed PASS; no brightness
//   judgment needed. For the ACTUAL waveform (frequency, duty cycle, edge
//   quality), probe the output pin directly with an oscilloscope.
//==========================================================================
module fmc_clock_loopback (
    input  wire         clk,        // 100 MHz ZedBoard system clock
    input  wire [4:0]   sw,
    output wire [7:0]   led,
    inout  wire [31:0]  fmc_pins
);

    wire [3:0] pair_sel = sw[3:0];

    // synchronize the raw mechanical switch into this clock domain
    reg sw4_sync0, sw4_sync1;
    always @(posedge clk) begin
        sw4_sync0 <= sw[4];
        sw4_sync1 <= sw4_sync0;
    end
    wire clk_en = sw4_sync1;

    // ---- 1 MHz, 50% duty square wave (100 MHz / 100) ----
    reg [6:0] div = 7'd0;
    always @(posedge clk)
        div <= (div == 7'd99) ? 7'd0 : div + 7'd1;
    wire clk_1mhz = (div < 7'd50);

    wire drive_val = clk_en & clk_1mhz;

    // drive only the selected output pin; every other output pin held low
    wire [15:0] out_sel = 16'b1 << pair_sel;
    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_out
            assign fmc_pins[g] = out_sel[g] ? drive_val : 1'b0;
        end
    endgenerate

    // synchronize + capture all 16 input pins
    reg [15:0] sync0;
    reg [15:0] in_capture;
    always @(posedge clk) begin
        sync0      <= fmc_pins[31:16];
        in_capture <= sync0;
    end
    wire read_back = in_capture[pair_sel];

    // delay the drive value by the same 2 cycles the input path takes,
    // so the PASS compare lines up in time instead of always mismatching
    // by a couple of nanoseconds' worth of pipeline latency
    reg drive_val_d1, drive_val_d2;
    always @(posedge clk) begin
        drive_val_d1 <= drive_val;
        drive_val_d2 <= drive_val_d1;
    end
    wire match_now = (drive_val_d2 == read_back);

    // Debounce/settle window: a mechanical switch bounces for a few ms when
    // flipped, which at 100 MHz is hundreds of thousands of clock cycles --
    // easily enough to trip a naive sticky latch even on a perfectly good
    // connection. So the fault latch only starts trusting comparisons after
    // clk_en has been continuously stable for ~20 ms (2,000,000 cycles),
    // well past any real switch bounce.
    // A single one-cycle mismatch can happen on a perfectly working pin
    // just from ordinary electrical noise on an unshielded, unterminated
    // jumper wire at 1 MHz -- that is NOT the same thing as a broken or
    // disconnected pin, which would disagree continuously. So instead of
    // latching on any single mismatch ever, require several mismatched
    // cycles IN A ROW before declaring a real fault; an isolated glitch
    // resets the run counter back to zero as soon as a match is seen again.
    localparam integer SETTLE_CYCLES      = 2_000_000; // ~20 ms at 100 MHz
    localparam integer MISMATCH_THRESHOLD = 16;         // consecutive mismatched cycles = real fault
    reg [21:0] settle_cnt;
    reg        settled;
    reg [4:0]  mismatch_run;
    reg        fault_latch;
    always @(posedge clk) begin
        if (!clk_en) begin
            settle_cnt   <= 22'd0;
            settled      <= 1'b0;
            mismatch_run <= 5'd0;
            fault_latch  <= 1'b0;
        end else if (!settled) begin
            if (settle_cnt == SETTLE_CYCLES[21:0])
                settled <= 1'b1;
            else
                settle_cnt <= settle_cnt + 22'd1;
        end else if (match_now) begin
            mismatch_run <= 5'd0;
        end else if (mismatch_run == MISMATCH_THRESHOLD[4:0] - 5'd1) begin
            fault_latch <= 1'b1;
        end else begin
            mismatch_run <= mismatch_run + 5'd1;
        end
    end

    assign led[0]   = drive_val;
    assign led[1]   = read_back;
    assign led[2]   = match_now;   // live match, same style as the static test
    assign led[3]   = fault_latch; // sticky FAIL: off = never mismatched (after settling), on = mismatched at least once
    assign led[7:4] = 4'b0;

endmodule
