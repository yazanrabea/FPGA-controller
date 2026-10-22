`timescale 1ns / 1ps
//==========================================================================
// phase7_link_jtag_top
//
// JTAG link step J3: phase7_link_top with LINK = "JTAG" -- the Phase 7
// step sequencer with its table loaded from the PC (register map v2,
// docs/link_register_map.md) over the J17 PROG cable (BSCANE2 USER4,
// jtag_link_bridge.sv) instead of a UART. Everything else is
// phase7_link_top unchanged (LD7 = link error, here a down-FIFO overrun).
//
// This wrapper exists only because a top-level rxd/txd with no pin stops the
// bitstream. PC side: tools/nemo_ctl (step J4). Board test: EXP-04 over JTAG
// (step J5).
//==========================================================================
module phase7_link_jtag_top (
    input  logic        clk,        // 100 MHz ZedBoard system clock
    output logic [7:0]  led,
    inout  wire  [31:0] fmc_pins
);
    phase7_link_top #(.LINK("JTAG")) u_core (
        .clk(clk), .led(led), .fmc_pins(fmc_pins),
        .rxd(1'b1), .txd()
    );
endmodule
