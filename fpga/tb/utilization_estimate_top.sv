`timescale 1ns / 1ps
//==========================================================================
// utilization_estimate_top
//
// NOT a functional design -- synthesis-only scaffolding to get a real
// (yosys xc7, not hand-counted) utilization number for the 26-cell
// controller described in docs/controller_spec.md §3, ahead of Phase 4's
// real top level (which will build the actual register file / link
// interface instead of the tied-off constants below). Instances are
// unrolled explicitly rather than generated from an array, since yosys's
// bundled Verilog frontend doesn't accept SystemVerilog unpacked array
// literals (`'{...}`).
//
// Not built by scripts/create_project.tcl, not simulated, not a stand-in
// for Phase 4. Run with:
//   yosys -p "read_verilog -sv fpga/src/sig_cell.sv fpga/src/cap_cell.sv \
//              fpga/src/run_ctrl.sv fpga/tb/utilization_estimate_top.sv; \
//              synth_xilinx -family xc7 -top utilization_estimate_top; stat"
//
// TICK_W=20 (not sig_cell/cap_cell's own default of 32) because that is
// the realistic width for this project: the largest tick count anywhere in
// config/nemo_config.yaml today is clk_piso's 150 us delay = 15,000 ticks
// (14 bits); 20 bits gives headroom to ~10.5 ms without the needless cost
// of the full 32-bit default. SERIAL_W/CAP_W are sized per pin to the real
// frame width (136 for sipo_in, 168 for piso_out) or 1 where that pin can
// never use SERIAL/CAPTURE-serial mode at all (cheapest possible shift
// register for a mode it'll never take).
//==========================================================================
module utilization_estimate_top (
    input  logic clk,
    input  logic rst_n,
    input  logic run_set,
    input  logic run_clear,
    input  logic apply_cmd,
    output logic [21:0] input_pins,   // 22 driven pins (stand-in for 22 FMC_LA outputs)
    input  logic [3:0]  output_pins   // 4 captured pins (stand-in for 4 FMC_LA inputs)
);

    localparam int TICK_W = 20;

    logic run, apply;
    run_ctrl u_run_ctrl (
        .clk(clk), .rst_n(rst_n),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd),
        .run(run), .apply(apply)
    );

    // generic sig_cell instance, tied off: cfg_* values don't matter for an area
    // estimate, only SERIAL_W (which hardware mode each cell supports) does.
    `define SIG_CELL_INST(name, serial_w, pin) \
        sig_cell #(.TICK_W(TICK_W), .SERIAL_W(serial_w)) name ( \
            .clk(clk), .rst_n(rst_n), .run(run), .apply(apply), \
            .cfg_type(3'd0), .cfg_idle_level(1'b0), \
            .cfg_delay('0), .cfg_param_a('0), .cfg_param_b('0), .cfg_cycles('0), \
            .cfg_msb_first(1'b1), .cfg_data('0), .cfg_bits('0), \
            .shift_strobe(1'b0), \
            .pin_out(pin), \
            .rising_edge(), .falling_edge(), .active(), .done() \
        )

    `SIG_CELL_INST(u_clk,      1, input_pins[0]);
    `SIG_CELL_INST(u_reset,    1, input_pins[1]);
    `SIG_CELL_INST(u_set,      1, input_pins[2]);
    `SIG_CELL_INST(u_rst_dsa,  1, input_pins[3]);
    `SIG_CELL_INST(u_pulse,    1, input_pins[4]);
    `SIG_CELL_INST(u_s0_p,     1, input_pins[5]);
    `SIG_CELL_INST(u_s1_p,     1, input_pins[6]);
    `SIG_CELL_INST(u_s2_p,     1, input_pins[7]);
    `SIG_CELL_INST(u_b0_dft,   1, input_pins[8]);
    `SIG_CELL_INST(u_b1_dft,   1, input_pins[9]);
    `SIG_CELL_INST(u_b2_dft,   1, input_pins[10]);
    `SIG_CELL_INST(u_s0_dft,   1, input_pins[11]);
    `SIG_CELL_INST(u_s1_dft,   1, input_pins[12]);
    `SIG_CELL_INST(u_s2_dft,   1, input_pins[13]);
    `SIG_CELL_INST(u_s3_dft,   1, input_pins[14]);
    `SIG_CELL_INST(u_sipo_in,  136, input_pins[15]);
    `SIG_CELL_INST(u_clk_sipo, 1, input_pins[16]);
    `SIG_CELL_INST(u_cs,       1, input_pins[17]);
    `SIG_CELL_INST(u_rst_sipo, 1, input_pins[18]);
    `SIG_CELL_INST(u_clk_piso, 1, input_pins[19]);
    `SIG_CELL_INST(u_shift,    1, input_pins[20]);
    `SIG_CELL_INST(u_rst_piso, 1, input_pins[21]);

    `undef SIG_CELL_INST

    `define CAP_CELL_INST(name, cap_w, pin) \
        cap_cell #(.TICK_W(TICK_W), .CAP_W(cap_w)) name ( \
            .clk(clk), .rst_n(rst_n), .run(run), .apply(apply), \
            .sync_in(pin), \
            .cfg_mode(2'd0), .cfg_msb_first(1'b1), .cfg_bits('0), \
            .capture_strobe(1'b0), \
            .level_out(), .edge_count(), .period_ticks(), .high_ticks(), \
            .period_valid(), .capture_reg(), .done() \
        )

    `CAP_CELL_INST(u_sipo_out,  1,   output_pins[0]);
    `CAP_CELL_INST(u_piso_out,  168, output_pins[1]);
    `CAP_CELL_INST(u_dft0_buff, 1,   output_pins[2]);
    `CAP_CELL_INST(u_dft1_buff, 1,   output_pins[3]);

    `undef CAP_CELL_INST

endmodule
