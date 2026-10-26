`timescale 1ns / 1ps
//==========================================================================
// virtual_chip
//
// Chip pipeline step C6 / EXP-08: a stand-in for the chip's SIPO / PISO path,
// built from Dima's UNMODIFIED RTL (fpga/reference/dima_blocks/: sipo.sv,
// sipo_wrapper.sv, piso.sv's piso2) plus the Tower-cell stubs
// (fpga/tb/tower_cell_stubs.sv: ANTENNA = no logic, DLY3 = a wire). Only
// vchip_top uses it; scripts/create_project.tcl adds those files for that top.
// NOT the real chip: no Y-Flash array, no ADC/TDC. Every clock and reset here
// is a pad input, exactly as on the chip.
//
//   sipo_in/clk_sipo/cs/rst_sipo --> u_frame (sipo)          parallel_out = the 136-bit frame
//                                --> u_wrap  (sipo_wrapper)  sel[23:0], sipo_out
//   phirst                       --> u_wrap  (steps sel through the frame's slices)
//   {frame, sel, 8'hC6} = 168 bits --> 4 x piso2 (PISO0 first) --> piso_out
//
// Why two SIPO instances: sipo_wrapper doesn't bring its sipo's parallel_out
// out on a port, and Vivado synthesis can't read it hierarchically. A second,
// standalone `sipo` on the same inputs holds the same state (same code, same
// clocks), so the PISO can return the frame. sipo_out comes from u_wrap.
//
// PISO packing (piso.sv's header): stage = {out1[13:0], tdc_out1[6:0],
// out0[13:0], tdc_out0[6:0]}, MSB first out; PISO0 is read first, PISO3 last
// (prev_serial_bit chain, PISO3's is 0). So stage k gets piso_vec[167-42k -: 42]
// and the 168 bits read on piso_out, MSB first, are exactly piso_vec:
//   piso_vec = {frame[135:0], sel[23:0], 8'hC6}   (Rahaf's choice, 2026-10-26)
// 8'hC6 = "C6", a fixed tail that shows the read is aligned.
//
// Expected from config/chip_sim_test.yaml after power-up (rst_sipo held HIGH,
// no phirst): frame = 0x5AA55A0FF0123456789ABCDEF0C3C3E7E7, sel[7:0] =
// frame[7:0] = E7, sel[23:8] = 0 (loaded only while rst_sipo is low; the FPGA
// starts at 0) -> piso_out = 0x5AA5...E7E7_0000E7C6. What sel[23:8] does after a
// rst_sipo pulse is one of the things EXP-08 looks at: in simulation it holds the
// previous frame's slice 0 (Dima Q1, CLAUDE.md §5); Vivado builds that async load
// from 16 latches gated by rst_n (scratch synthesis, 2026-10-26), which may give 0.
//==========================================================================
module virtual_chip (
    input  logic sipo_in,
    input  logic clk_sipo,
    input  logic cs,
    input  logic rst_sipo,    // active low (sipo.sv rst_n)
    input  logic clk_piso,
    input  logic shift,       // piso2 load: 0 = sample, 1 = shift
    input  logic rst_piso,    // active low (piso2 rst_n)
    input  logic phirst,
    output logic sipo_out,
    output logic piso_out
);
    localparam int WL = 16, BL = 8;            // Dima's defaults: WIDTH = 8 + 8*16 = 136
    localparam int FW = BL + 8 * WL;

    // ---- SIPO side ----
    logic [FW-1:0] frame;
    logic          frame_sipo_out;              // same as sipo_out; not used
    sipo #(.WL_num(WL), .BL_num(BL)) u_frame (
        .clk(clk_sipo), .rst_n(rst_sipo), .serial_in(sipo_in), .clk_s(cs),
        .parallel_out(frame), .sipo_out(frame_sipo_out));

    logic [23:0] sel;
    sipo_wrapper #(.WL_num(WL), .BL_num(BL)) u_wrap (
        .clk(clk_sipo), .rst_n(rst_sipo), .serial_in(sipo_in), .clk_s(cs),
        .phirst(phirst), .sel(sel), .sipo_out(sipo_out));

    // ---- PISO side: 4 chained piso2 stages, 42 bits each ----
    logic [167:0] piso_vec;
    assign piso_vec = {frame, sel, 8'hC6};

    logic [3:0] ser;                             // ser[k] = stage k's serial_out
    genvar k;
    generate
        for (k = 0; k < 4; k++) begin : g_piso
            localparam int HI = 167 - 42 * k;
            piso2 u_piso (
                .clk(clk_piso), .rst_n(rst_piso), .load(shift),
                .out1    (piso_vec[HI      -: 14]),
                .tdc_out1(piso_vec[HI - 14 -: 7]),
                .out0    (piso_vec[HI - 21 -: 14]),
                .tdc_out0(piso_vec[HI - 35 -: 7]),
                .prev_serial_bit(k == 3 ? 1'b0 : ser[(k + 1) % 4]),
                .serial_out(ser[k]));
        end
    endgenerate
    assign piso_out = ser[0];
endmodule
