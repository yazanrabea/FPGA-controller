`timescale 1ns / 1ps
//==========================================================================
// bscane2_sim_stub.sv -- SIMULATION ONLY, never in fpga/src (never built).
//
// Stand-in for the Xilinx BSCANE2 primitive, so a top that uses
// jtag_link_bscan.sv simulates without the unisim library. It does no TAP
// state machine of its own: a testbench drives the decoded signals
// (TCK/SEL/CAPTURE/SHIFT/UPDATE/TDI) on a `jtag_tap_model` instance, and
// every BSCANE2 stub below it finds that instance by name (upward
// hierarchical reference `jtag_tap`), so the design under test is used
// completely unmodified. Put exactly one `jtag_tap_model jtag_tap (...)` in
// the scope that contains the DUT (see fpga/tb/jtag_link_e2e_tb.sv).
//==========================================================================
module jtag_tap_model (
    input  logic tck,
    input  logic sel,
    input  logic capture,
    input  logic shift,
    input  logic update,
    input  logic tdi,
    output logic tdo
);
    logic tdo_v = 1'b0;     // written by the BSCANE2 stub
    assign tdo = tdo_v;
endmodule

module BSCANE2 #(
    parameter         DISABLE_JTAG = "FALSE",
    parameter integer JTAG_CHAIN   = 1
) (
    output wire CAPTURE,
    output wire DRCK,
    output wire RESET,
    output wire RUNTEST,
    output wire SEL,
    output wire SHIFT,
    output wire TCK,
    output wire TDI,
    output wire TMS,
    output wire UPDATE,
    input  wire TDO
);
    assign TCK     = jtag_tap.tck;
    assign SEL     = jtag_tap.sel;
    assign CAPTURE = jtag_tap.capture;
    assign SHIFT   = jtag_tap.shift;
    assign UPDATE  = jtag_tap.update;
    assign TDI     = jtag_tap.tdi;
    assign DRCK    = 1'b0;
    assign RESET   = 1'b0;
    assign RUNTEST = 1'b0;
    assign TMS     = 1'b0;
    always @* jtag_tap.tdo_v = TDO;
endmodule
