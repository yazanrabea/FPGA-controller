`timescale 1ns / 1ps
//==========================================================================
// IOBUF simulation stub (testbench only; Vivado synthesis uses the real
// Xilinx primitive). Same ports as the UNISIM IOBUF that chip_top.sv
// instantiates for pad readback (verification plan Step 2):
//   T = 0: drive I onto the pad IO;  T = 1: high-Z.
//   O = the pad, as its input buffer sees it.
// A testbench can `force` the pad net to model a pad pulled the wrong way;
// O then shows the forced value, as the real input buffer would.
//==========================================================================
module IOBUF (
    output wire O,
    inout  wire IO,
    input  wire I,
    input  wire T
);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule
