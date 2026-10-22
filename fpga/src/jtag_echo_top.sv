`timescale 1ns / 1ps
//==========================================================================
// jtag_echo_top
//
// JTAG link step J1, feasibility on the board (docs/experiments/EXP-05_*.md):
// a BSCANE2 user data register on USER4 (IR 0x23), reachable over the J17
// PROG cable that also programs the FPGA. jtag_echo_core.sv answers each
// DR scan with the inverse of the previous one, so scripts/jtag_echo_test.tcl
// (xsdb) can check both directions and time the transfers.
//
// USER4, not USER1: hw_server scans USER1 on its own (Vivado's debug hub
// lives there by default), which overwrote our register: ~2.5% of reads came
// back all ones without `jtag lock`, the value was cleared at every xsdb
// connect, and the LEDs flickered while idle (EXP-05, docs/issues.md).
//
// LEDs: LD0-LD7 = bits [7:0] of the last scan's data, brought into the
// 100 MHz domain through a 2-FF synchronizer (CLAUDE.md §8; the 8 bits can
// tear for a tick while a scan lands, harmless on LEDs).
// No FMC pins: nothing is driven on the daughter board.
//==========================================================================
module jtag_echo_top #(
    parameter int DR_BITS    = 1024,
    parameter int JTAG_CHAIN = 4        // USER1..4 = IR 0x02 / 0x03 / 0x22 / 0x23
) (
    input  logic       clk,     // 100 MHz ZedBoard system clock
    output logic [7:0] led
);
    logic tck, tdi, tdo, sel, capture, shift, update;

    BSCANE2 #(
        .JTAG_CHAIN(JTAG_CHAIN)
    ) u_bscan (
        .CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel),
        .SHIFT(shift), .TCK(tck), .TDI(tdi), .TMS(), .UPDATE(update),
        .TDO(tdo)
    );

    logic [DR_BITS-1:0] last;
    jtag_echo_core #(.DR_BITS(DR_BITS)) u_core (
        .tck(tck), .sel(sel), .capture(capture), .shift(shift), .update(update),
        .tdi(tdi), .tdo(tdo), .last(last), .n_updates()
    );

    // ---- last[7:0] -> 100 MHz domain -> LEDs ----
    (* ASYNC_REG = "TRUE" *) logic [7:0] led_s0, led_s1;
    always_ff @(posedge clk) begin
        led_s0 <= last[7:0];
        led_s1 <= led_s0;
    end
    assign led = led_s1;

endmodule
