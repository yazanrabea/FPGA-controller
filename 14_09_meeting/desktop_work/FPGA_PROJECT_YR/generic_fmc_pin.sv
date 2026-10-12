`timescale 1ns / 1ps
//==========================================================================
// generic_fmc_pin
// One bidirectional FMC pin. As an output it drives either a static level
// or a PWM waveform (pseudo-analog stimulus through an external RC filter).
// As an input it double-flop synchronizes and captures the pad level.
// Instantiated 32x by generic_fmc_io_top.
//==========================================================================
module generic_fmc_pin #(
    parameter          IS_OUTPUT  = 1'b0,   // 1 = FPGA drives fmc_pin, 0 = FPGA reads fmc_pin
    parameter          PWM_MODE   = 1'b0,   // 1 = drive PWM, 0 = drive STATIC_VAL (only used if IS_OUTPUT=1)
    parameter          STATIC_VAL = 1'b0,   // level driven when PWM_MODE=0
    parameter [7:0]    PWM_DUTY   = 8'd128  // 0-255 -> ~0-100% duty, used when PWM_MODE=1
)(
    input  wire        clk,
    input  wire [7:0]  pwm_cnt,   // shared free-running PWM counter (from generic_fmc_io_top)
    inout  wire        fmc_pin,
    output reg         pin_sync   // synchronized pad level: mirrors drive when output, reads DUT when input
);

    wire drive_val = PWM_MODE ? (pwm_cnt < PWM_DUTY) : STATIC_VAL;
    assign fmc_pin = IS_OUTPUT ? drive_val : 1'bz;

    reg sync0;
    always @(posedge clk) begin
        sync0    <= fmc_pin;
        pin_sync <= sync0;
    end

endmodule
