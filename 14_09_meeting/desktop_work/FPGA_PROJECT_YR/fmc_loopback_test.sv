`timescale 1ns / 1ps
//==========================================================================
// fmc_loopback_test
//
// Basic bring-up / self-test for the ZedBoard FMC connector (32x LA_P,
// VADJ = 1.8V). Confirms the FPGA can actually drive AND read back every
// pin in the mapping, before the NEMO board is connected.
//
// Pin split (fits the 32-pin / 16-pair FMC layout):
//   fmc_pins[15:0]  = OUTPUTS - FPGA drives a slow walking-one pattern
//   fmc_pins[31:16] = INPUTS  - FPGA reads them back and shows on LEDs
//
// HOW TO TEST
//   Jumper fmc_pins[i] (output) to fmc_pins[i+16] (input) for each pin you
//   want to check, e.g. index 0 (LA00_P_CC) -> index 16 (LA16_P). Program
//   the board: LD[7:0] should show a single lit LED "walking" once every
//   ~0.5s, in step with whichever output pin(s) you jumpered. page_sel
//   (SW0) picks which half of the 16 inputs LD[7:0] is currently showing.
//==========================================================================
module fmc_loopback_test (
    input  wire         clk,        // 100 MHz ZedBoard system clock
    input  wire         page_sel,   // SW0: 0 = show inputs[7:0], 1 = show inputs[15:8]
    output wire [7:0]   led,        // on-board LEDs, mirror the selected input byte
    inout  wire [31:0]  fmc_pins    // FMC LA00_P..LA31_P, see pin_mapping (FMC-FPGA).xlsx
);

    // ---- slow tick generator: ~2 ticks/sec at 100 MHz clk ----
    reg [25:0] div = 26'd0;
    wire tick = (div == 26'd49_999_999);
    always @(posedge clk)
        div <= tick ? 26'd0 : div + 26'd1;

    // ---- walking-one index across the 16 output pins ----
    reg [3:0] idx = 4'd0;
    always @(posedge clk)
        if (tick)
            idx <= idx + 4'd1;

    (* mark_debug = "true" *) wire [15:0] out_pattern = 16'b1 << idx;
    assign fmc_pins[15:0] = out_pattern;

    // ---- input pins: double-flop synchronize + capture ----
    reg [15:0] sync0;
    (* mark_debug = "true" *) reg [15:0] in_capture;
    always @(posedge clk) begin
        sync0      <= fmc_pins[31:16];
        in_capture <= sync0;
    end

    assign led = page_sel ? in_capture[15:8] : in_capture[7:0];

endmodule
