///////////////////////////////////////////////////////////////////////////////
// piso_stage.sv
//
// Parameterized PISO stage for ADC/TDC data serialization.
//
// Total shift register width: 2*(OUT + TDC_OUT)
//   Default: 2 * (14 + 7) = 42 bits
//
// Bit packing (MSB ? LSB, i.e. first-out ? last-out):
//   [41:28] = out1[13:0]      (ADC1 data,   shifted out first)
//   [27:21] = tdc_out1[6:0]
//   [20:7]  = out0[13:0]
//   [6:0]   = tdc_out0[6:0]  (shifted out last from this stage)
//
// Operation:
//   load=0 (sample): all stages latch parallel inputs on posedge clk
//   load=1 (shift):  stage shifts left; MSB exits via serial_out,
//                    prev_serial_bit enters at LSB
//
// Chaining (PISO0 ? PISO1 ? PISO2 ? PISO3):
//   - PISO3.prev_serial_bit = 1'b0
//   - PISO2.prev_serial_bit = PISO3.serial_out
//   - PISO1.prev_serial_bit = PISO2.serial_out
//   - PISO0.prev_serial_bit = PISO1.serial_out
//   - Read from PISO0.serial_out
//
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module piso2 #(
    parameter OUT     = 14,
    parameter TDC_OUT = 7,
    // Derived: do not override
    parameter WIDTH   = 2 * (OUT + TDC_OUT)   // 42 bits default
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 load,           // 0=sample, 1=shift

    // Parallel ADC/TDC inputs
    input  logic [OUT-1:0]       out0,
    input  logic [OUT-1:0]       out1,
    input  logic [TDC_OUT-1:0]   tdc_out0,
    input  logic [TDC_OUT-1:0]   tdc_out1,

    // Chain input from next stage (enters at LSB)
    input  logic                 prev_serial_bit,
    // Serial output (MSB-first)
    output logic                 serial_out
);

    // -------------------------------------------------------------------------
    // Antenna protection (simulation-ready)
    // -------------------------------------------------------------------------
    genvar i;
    generate
        // out0 bits
        for (i = 0; i < OUT; i=i+1) begin : GEN_OUT0_ANT
            ANTENNA_18_SVT_WTN ant_out0 (.I(out0[i]));
        end
        // out1 bits
        for (i = 0; i < OUT; i=i+1) begin : GEN_OUT1_ANT
            ANTENNA_18_SVT_WTN ant_out1 (.I(out1[i]));
        end
        // tdc_out0 bits
        for (i = 0; i < TDC_OUT; i=i+1) begin : GEN_TDC0_ANT
            ANTENNA_18_SVT_WTN ant_tdc0 (.I(tdc_out0[i]));
        end
        // tdc_out1 bits
        for (i = 0; i < TDC_OUT; i=i+1) begin : GEN_TDC1_ANT
            ANTENNA_18_SVT_WTN ant_tdc1 (.I(tdc_out1[i]));
        end
        // Control signals
        ANTENNA_18_SVT_WTN ant_clk  (.I(clk));
        ANTENNA_18_SVT_WTN ant_rst  (.I(rst_n));
        ANTENNA_18_SVT_WTN ant_load (.I(load));
    endgenerate

    // -------------------------------------------------------------------------
    // Shift register
    // -------------------------------------------------------------------------
    logic [WIDTH-1:0] stage;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage <= '0;
        end else if (!load) begin
            // Sample: latch all parallel inputs directly — no flattening needed
            stage <= {out1, tdc_out1, out0, tdc_out0};
        end else begin
            // Shift left: MSB exits via serial_out, prev_serial_bit enters LSB
            stage <= {stage[WIDTH-2:0], prev_serial_bit};
        end
    end

    // MSB is always the current output bit
   // -------------------------------------------------------------------------
    // Output delay chain — 4x DLY3_X4_18_SVT_WTN in series
    // Adds hold margin on the shift path to satisfy hold timing constraints
    // -------------------------------------------------------------------------
    logic dly0_out, dly1_out, dly2_out;

    DLY3_X4_18_SVT_WTN u_dly0 (.A(stage[WIDTH-1]), .Q(dly0_out));
    DLY3_X4_18_SVT_WTN u_dly1 (.A(dly0_out),       .Q(dly1_out));
    DLY3_X4_18_SVT_WTN u_dly2 (.A(dly1_out),       .Q(dly2_out));
    DLY3_X4_18_SVT_WTN u_dly3 (.A(dly2_out),       .Q(serial_out));

endmodule