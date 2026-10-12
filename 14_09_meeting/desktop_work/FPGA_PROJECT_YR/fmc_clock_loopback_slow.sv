`timescale 1ns / 1ps
//==========================================================================
// fmc_clock_loopback_slow
//
// Same self-check as fmc_clock_loopback.sv, but with a ~100 Hz clock
// instead of 1 MHz -- slow enough that a standard handheld multimeter can
// accurately track and average it (multimeters are built for DC/mains-
// frequency signals; they cannot reliably average a 1 MHz square wave,
// which is why that version gave unstable, meaningless readings).
//
// Everything else -- pin convention, switches, LED meanings, fault-latch
// logic -- is identical to fmc_clock_loopback.sv. See that file's header
// comment for the full explanation. Reuses the same constraints file,
// fmc_clock_loopback.xdc (port names are identical).
//
// Expected multimeter reading (DC volts, on the selected output pin,
// sw[4]=1): ~0.9V (50% duty average of a 0V/1.8V square wave), now with a
// STABLE, settled reading instead of the jittery one from the 1 MHz version.
//==========================================================================
module fmc_clock_loopback_slow (
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

    // ---- ~100 Hz, 50% duty square wave (100 MHz / 1,000,000) ----
    localparam integer HALF_PERIOD = 500_000; // cycles high, then 500,000 low -> 100 Hz
    reg [19:0] div = 20'd0;
    always @(posedge clk)
        div <= (div == (HALF_PERIOD*2 - 1)) ? 20'd0 : div + 20'd1;
    wire clk_100hz = (div < HALF_PERIOD[19:0]);

    wire drive_val = clk_en & clk_100hz;

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

    // delay the drive value by the same 2 cycles the input path takes
    reg drive_val_d1, drive_val_d2;
    always @(posedge clk) begin
        drive_val_d1 <= drive_val;
        drive_val_d2 <= drive_val_d1;
    end
    wire match_now = (drive_val_d2 == read_back);

    // same debounce/settle + consecutive-mismatch fault latch as before
    localparam integer SETTLE_CYCLES      = 2_000_000; // ~20 ms at 100 MHz
    localparam integer MISMATCH_THRESHOLD = 16;
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

    assign led[0]   = drive_val;   // now slow enough to actually see blink (~5Hz-ish visible pulsing at 100Hz is borderline; still mostly a glow)
    assign led[1]   = read_back;
    assign led[2]   = match_now;
    assign led[3]   = fault_latch;
    assign led[7:4] = 4'b0;

endmodule
