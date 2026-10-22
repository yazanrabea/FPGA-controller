`timescale 1ns / 1ps
//==========================================================================
// ICARUS-ONLY stand-in for fpga/reference/dima_blocks/sipo_wrapper.sv.
//
// Dima's file drives output `sel` from both a continuous assign (sel[7:0])
// and an always_ff (sel[23:8]). Disjoint bits, so legal SystemVerilog as we
// read IEEE 1800 §6.5, but Icarus 12 refuses to elaborate it ("Part select is
// double-driving unresolved wire"). This copy is his module with ONE change:
// sel[23:8] is held in an internal reg `sel_hi` and both halves are joined by
// one assign. Same ports, parameters, reset, index logic and quirks (Q1/Q2).
// scripts/run_phase6_sim.sh uses it only when SIM=icarus; xsim compiles
// Dima's original. Do not use outside simulation.
//==========================================================================
module sipo_wrapper #(
    parameter WL_num = 16,
    parameter BL_num = 8,
    parameter WIDTH  = BL_num + 8*WL_num
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic             serial_in,
    input  logic             clk_s,
    input  logic             phirst,
    output logic [23:0]      sel,
    output logic             sipo_out
);

    logic [WIDTH-1:0] parallel_out;

    sipo #(
        .WL_num(WL_num),
        .BL_num(BL_num),
        .WIDTH (WIDTH)
    ) u_sipo (
        .clk          (clk),
        .rst_n        (rst_n),
        .serial_in    (serial_in),
        .clk_s        (clk_s),
        .parallel_out (parallel_out),
        .sipo_out     (sipo_out)
    );

    // --- the one change: sel[23:8] lives in sel_hi ---
    logic [15:0] sel_hi;
    assign sel = {sel_hi, parallel_out[7:0]};

    logic [$clog2(WIDTH)-1:0] index;

    always_ff @(posedge phirst or negedge rst_n) begin
        if (!rst_n) begin
            index  <= 24;                    // first 24 already used
            sel_hi <= parallel_out[23:8];    // initial load (reads parallel_out while in reset: Q1)
        end
        else begin
            sel_hi <= parallel_out[index +: 16];
            index  <= index + 16;            // never wraps (Q2)
        end
    end

endmodule
