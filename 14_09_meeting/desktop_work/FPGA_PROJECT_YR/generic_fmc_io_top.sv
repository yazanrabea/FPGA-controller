`timescale 1ns / 1ps
//==========================================================================
// generic_fmc_io_top
//
// Generic, code-configurable 32-pin digital/PWM I/O tester for the ZedBoard
// FMC LA_P connector (VADJ = 1.8V -> LVCMOS18). Reusable for any board the
// lab wires onto this FMC mapping (currently: NEMO).
//
// HOW TO USE
//   1. Edit the DIR / PWM_EN / STATIC_VAL / DUTY tables below to set each
//      pin's direction and drive behavior, then re-run synthesis and
//      implementation and program the board.
//   2. pin_capture[31:0] mirrors every pin's synchronized pad level
//      (output pins read back what they drive; input pins read the DUT).
//      It carries mark_debug, so Vivado's "Set Up Debug" flow can drop an
//      ILA on it directly from the implemented design -- no extra
//      software or protocol needed to see what's happening on each pin.
//   3. For PWM ("analog") pins, add an external RC low-pass filter on that
//      pin to turn the PWM into a smoothed 0-1.8V DC-ish level. Default
//      PWM frequency = clk/256 = 100MHz/256 ~= 390 kHz.
//==========================================================================
module generic_fmc_io_top (
    input  wire         clk,        // 100 MHz ZedBoard system clock
    inout  wire [31:0]  fmc_pins    // FMC LA00_P..LA31_P, see pin_mapping (FMC-FPGA).xlsx
);

    // ---------------------------------------------------------------
    // >>> EDIT HERE to configure each of the 32 pins <<<
    //   DIR[i]        1 = output (FPGA drives), 0 = input (FPGA reads)
    //   PWM_EN[i]     1 = PWM drive, 0 = static drive  (ignored when DIR[i]=0)
    //   STATIC_VAL[i] level driven when PWM_EN[i]=0 and DIR[i]=1
    //   DUTY[i]       8-bit PWM duty (0-255 ~ 0-100%) when PWM_EN[i]=1
    //
    // Index -> FMC signal (from pin_mapping (FMC-FPGA).xlsx):
    //   0:LA00_CC 1:LA01_CC 2:LA02  3:LA03  4:LA04  5:LA05  6:LA06  7:LA07
    //   8:LA08    9:LA09   10:LA10 11:LA11 12:LA12 13:LA13 14:LA14 15:LA15
    //  16:LA16   17:LA17_CC 18:LA18_CC 19:LA19 20:LA20 21:LA21 22:LA22 23:LA23
    //  24:LA24   25:LA25   26:LA26 27:LA27 28:LA28 29:LA29 30:LA30 31:LA31
    // ---------------------------------------------------------------
    localparam [31:0]  DIR        = 32'h0000_0000; // default: all 32 pins are inputs
    localparam [31:0]  PWM_EN     = 32'h0000_0000;
    localparam [31:0]  STATIC_VAL = 32'h0000_0000;
    localparam [255:0] DUTY       = {32{8'd128}};  // 8 bits/pin, default 50%

    reg [7:0] pwm_cnt = 8'd0;
    always @(posedge clk)
        pwm_cnt <= pwm_cnt + 8'd1;

    (* mark_debug = "true" *) wire [31:0] pin_capture;

    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : g_pin
            generic_fmc_pin #(
                .IS_OUTPUT  (DIR[i]),
                .PWM_MODE   (PWM_EN[i]),
                .STATIC_VAL (STATIC_VAL[i]),
                .PWM_DUTY   (DUTY[i*8 +: 8])
            ) u_pin (
                .clk      (clk),
                .pwm_cnt  (pwm_cnt),
                .fmc_pin  (fmc_pins[i]),
                .pin_sync (pin_capture[i])
            );
        end
    endgenerate

endmodule
