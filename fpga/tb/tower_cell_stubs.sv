`timescale 1ns / 1ps
//==========================================================================
// Simulation stubs for the two Tower standard cells Dima's piso.sv
// instantiates (fpga/reference/dima_blocks/piso.sv). Testbench only -- the
// real cells are in the Tower PDK, which we don't have.
//   ANTENNA_18_SVT_WTN: antenna-protection diode, electrically no logic -> sink.
//   DLY3_X4_18_SVT_WTN: hold-fix delay buffer -> zero-delay buffer here. The
//     real delay (4 in series on serial_out) is part of the chip delay that
//     sipo_piso.check_piso_read's chip_delay_ticks stands for; the
//     testbench adds it as one lumped delay on piso_out instead.
//==========================================================================
module ANTENNA_18_SVT_WTN (input logic I);
endmodule

module DLY3_X4_18_SVT_WTN (input logic A, output logic Q);
    assign Q = A;
endmodule
