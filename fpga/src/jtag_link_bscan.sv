`timescale 1ns / 1ps
//==========================================================================
// jtag_link_bscan
//
// JTAG link: BSCANE2 + jtag_link_bridge, the drop-in replacement for the
// uart_rx/uart_tx pair in front of link_frame.sv (step J3 wires it into the
// link tops). USER4 by default: hw_server scans USER1 on its own and
// overwrote the register there (EXP-05, docs/issues.md).
//
// The XDC of a top using this needs the TCK clock, as in jtag_echo_top.xdc:
//   create_clock -name jtag_tck -period 33.333 [get_pins <path>/u_bscan/TCK]
//   set_clock_groups -asynchronous -group [get_clocks sys_clk_pin] -group [get_clocks jtag_tck]
//==========================================================================
module jtag_link_bscan #(
    parameter int JTAG_CHAIN = 4,    // USER1..4 = IR 0x02 / 0x03 / 0x22 / 0x23
    parameter int DR_BITS    = 1024,
    parameter int FIFO_AW    = 8,
    parameter int RX_GAP     = 32
) (
    input  logic       clk,
    input  logic       rst_n,
    output logic [7:0] rx_byte,
    output logic       rx_byte_valid,
    input  logic [7:0] tx_byte,
    input  logic       tx_send,
    output logic       tx_busy,
    output logic       dn_overflow
);
    logic tck, tdi, tdo, sel, capture, shift, update;

    BSCANE2 #(.JTAG_CHAIN(JTAG_CHAIN)) u_bscan (
        .CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel),
        .SHIFT(shift), .TCK(tck), .TDI(tdi), .TMS(), .UPDATE(update),
        .TDO(tdo)
    );

    jtag_link_bridge #(.DR_BITS(DR_BITS), .FIFO_AW(FIFO_AW), .RX_GAP(RX_GAP)) u_bridge (
        .tck(tck), .sel(sel), .capture(capture), .shift(shift), .update(update),
        .tdi(tdi), .tdo(tdo),
        .clk(clk), .rst_n(rst_n),
        .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
        .dn_overflow(dn_overflow)
    );

endmodule
