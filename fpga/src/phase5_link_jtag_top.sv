`timescale 1ns / 1ps
//==========================================================================
// phase5_link_jtag_top
//
// JTAG link step J3: phase5_link_top with LINK = "JTAG" -- the Phase 5
// runtime link (docs/link_register_map.md, Phase 5 map) carried over the
// J17 PROG cable (BSCANE2 USER4, jtag_link_bridge.sv) instead of a UART.
// Everything else is phase5_link_top unchanged: same 5 loopback cells, same
// switches and LEDs (LD5 = link error, here a down-FIFO overrun).
//
// This wrapper exists only because a top-level rxd/txd with no pin stops the
// bitstream (rxd/txd are still unconstrained for the UART build). PC side:
// tools/nemo_ctl (step J4). Board test: EXP-02 over JTAG (step J5).
//==========================================================================
module phase5_link_jtag_top (
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
