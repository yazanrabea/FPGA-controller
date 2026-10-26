`timescale 1ns / 1ps
//==========================================================================
// vchip_top
//
// Chip pipeline step C6 / EXP-08: chip_top (the controller, unchanged, same
// chip_pkg and PC tools as EXP-07) + virtual_chip (Dima's unmodified SIPO /
// PISO RTL) in one bitstream, on separate pins. Jumper wires on the HTG-FMC
// headers connect them, the way the real chip will be connected
// (config/exp08_vchip.yaml; the table is repeated in vchip_top.xdc).
//
//   PC --J17--> chip_top --ctl_out pins--> jumpers --vc_in pins--> virtual_chip
//   PC <--J17-- chip_top <--ctl_in pins--  jumpers <--vc_out pins-- virtual_chip
//
// Pin budget: the 32 LA_P pins can't hold the controller's 26 and the virtual
// chip's 10, so the controller's 7 DFT outputs (b0..b2_dft, s0..s3_dft) are
// left inside (not on a pin; Vivado removes their logic). vchip_pkg.sv
// (generated) says which chip_top outputs are pinned: ctl_out[k] =
// chip_out[CTL_SIG[k]]. The 4 controller inputs stay pinned (dft0/1_buff
// have nothing connected and read 0, PULLDOWN).
//
// vc_in / vc_out order (fixed, = config/exp08_vchip.yaml, checked by the
// generator): vc_in = {phirst, rst_piso, shift, clk_piso, rst_sipo, cs,
// clk_sipo, sipo_in} (bit 0 = sipo_in), vc_out = {piso_out, sipo_out}.
// The virtual chip's inputs are used as they arrive (clocks and async resets
// straight from the pads, as on the chip), no synchronizer: they ARE its
// clocks. LEDs: chip_top's.
//==========================================================================
module vchip_top (
    input  logic                         clk,      // 100 MHz system clock
    output logic [7:0]                   led,
    output logic [vchip_pkg::N_CTL-1:0]  ctl_out,  // controller -> chip inputs (minus DFT)
    input  logic [chip_pkg::N_CAP-1:0]   ctl_in,   // chip outputs -> controller
    input  logic [7:0]                   vc_in,    // -> virtual chip (from the jumpers)
    output logic [1:0]                   vc_out    // virtual chip -> jumpers
);
    // ---- the controller, exactly as chip_top ----
    logic [chip_pkg::N_SIG-1:0] chip_out;
    chip_top u_ctl (.clk(clk), .led(led), .chip_out(chip_out), .chip_in(ctl_in));

    genvar k;
    generate
        for (k = 0; k < vchip_pkg::N_CTL; k++) begin : g_ctl
            assign ctl_out[k] = chip_out[vchip_pkg::CTL_SIG[k]];
        end
    endgenerate

    // ---- the virtual chip ----
    virtual_chip u_vc (
        .sipo_in (vc_in[0]), .clk_sipo(vc_in[1]), .cs(vc_in[2]), .rst_sipo(vc_in[3]),
        .clk_piso(vc_in[4]), .shift(vc_in[5]), .rst_piso(vc_in[6]), .phirst(vc_in[7]),
        .sipo_out(vc_out[0]), .piso_out(vc_out[1]));
endmodule
