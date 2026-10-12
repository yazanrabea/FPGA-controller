`timescale 1ns / 1ps
//==========================================================================
// fmc_selectable_loopback
//
// Self-contained FPGA loopback checker for the ZedBoard FMC connector.
// No oscilloscope or external tool needed -- the FPGA drives one pin and
// reads its paired pin back, and shows the result directly on LEDs.
//
// Pin split (same convention as fmc_loopback_test):
//   fmc_pins[15:0]  = OUTPUTS
//   fmc_pins[31:16] = INPUTS
//   pair i (0-15)   = output pin i  <->  input pin i+16
//
// HOW TO USE
//   sw[3:0] : pick which pair (0-15) to test
//   sw[4]   : the value to drive on that pair's output pin (flip it by hand)
//   LD0     : mirrors sw[4] -- the value being driven right now
//   LD1     : the value read back on the paired input pin
//   LD2     : PASS -- lit whenever LD0 == LD1
//
//   Jumper (or SMA coax) output pin `sw[3:0]` to input pin `sw[3:0]+16`,
//   flip sw[4] a few times, and confirm LD1 follows LD0 and LD2 stays lit.
//   Change sw[3:0] to move on to the next pair.
//==========================================================================
module fmc_selectable_loopback (
    input  wire         clk,
    input  wire [4:0]   sw,
    output wire [7:0]   led,
    inout  wire [31:0]  fmc_pins
);

    wire [3:0] pair_sel  = sw[3:0];
    wire       drive_val = sw[4];

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

    assign led[0]   = drive_val;
    assign led[1]   = read_back;
    assign led[2]   = (drive_val == read_back);
    assign led[7:3] = 5'b0;

endmodule
