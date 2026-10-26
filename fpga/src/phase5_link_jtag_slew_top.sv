`timescale 1ns / 1ps
//==========================================================================
// phase5_link_jtag_slew_top
//
// EXP-06 follow-up (docs/issues.md, "overshoot / undershoot of 0.4-0.7 V"):
// exactly phase5_link_jtag_top, but its XDC sets DRIVE 4 (baseline: 12 mA) on
// the five driven loopback outputs (fmc_pins[0..4]), to see whether a weaker
// driver reduces the ringing on the jumper wires. The baseline already had
// SLEW SLOW (Vivado's default, per its I/O report), so DRIVE is the one change. A separate top so the
// verified phase5_link_jtag_top (EXP-02 / EXP-06 baseline) stays unchanged.
// No logic difference and no pin moves: only output buffer settings.
//==========================================================================
module phase5_link_jtag_slew_top (
    input  logic        clk,        // 100 MHz ZedBoard system clock
    input  logic [2:0]  sw,
    output logic [7:0]  led,
    inout  wire  [31:0] fmc_pins
);
    phase5_link_top #(.LINK("JTAG")) u_core (
        .clk(clk), .sw(sw), .led(led), .fmc_pins(fmc_pins),
        .rxd(1'b1), .txd()
    );
endmodule
