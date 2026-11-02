`timescale 1ns / 1ps
//==========================================================================
// sample_loopback_top
//
// Verification plan 2026-11-01 Step 3: the in-FPGA logic analyser
// (sample_cell.sv) on the Phase 7 loopback bench. phase7_link_top with
// LINK = "JTAG" (as phase7_link_jtag_top, EXP-04) and SAMPLER = 1: the same
// sequencer, step table, 5 sig + 5 cap cells and pins (outputs LA00-04_P,
// inputs LA16-20_P through the 5 jumpers), plus a 16 x 4096 sample record
// of those 10 pins, set up and read over the link (registers 0x0020-0x0037,
// samples at 0x4000, docs/link_register_map.md "v2 sampler").
//
// Pins and XDC: fpga/constraints/sample_loopback_top.xdc = phase7_link_jtag_top.xdc
// (no pin moved). PC side: tools/nemo_ctl/samples.py, link.SeqLink sampler_*.
// [simulated] fpga/tb/sample_loopback_top_tb.sv (the core over UART). Not
// built or run on the board yet.
//==========================================================================
module sample_loopback_top (
    input  logic        clk,        // 100 MHz ZedBoard system clock
    output logic [7:0]  led,
    inout  wire  [31:0] fmc_pins
);
    phase7_link_top #(.LINK("JTAG"), .SAMPLER(1'b1)) u_core (
        .clk(clk), .led(led), .fmc_pins(fmc_pins),
        .rxd(1'b1), .txd()
    );
endmodule
