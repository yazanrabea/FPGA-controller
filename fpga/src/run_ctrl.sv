`timescale 1ns / 1ps
//==========================================================================
// run_ctrl
//
// Owns the global RUN/STOP state and relays a clean, one-cycle APPLY pulse
// to every sig_cell/cap_cell instance -- per generic_controller_prompt.md
// §2: "link RX -> shadow registers -> atomic APPLY -> active registers
// -> one generic cell per chip pin, sharing one timebase and one global
// RUN/STOP". The "timebase" itself is just the 100 MHz `clk` wired straight
// to every cell (1 clk cycle = 1 tick) -- there is nothing to divide or
// generate here, so this module's job is purely command handling.
//
// `run_set`/`run_clear`/`apply_cmd` are treated as potentially asynchronous
// (e.g. a switch in Phase 4 bring-up, or a link register-write strobe in
// Phase 5 -- this module works correctly either way): each gets a 2-FF
// synchronizer plus rising-edge detection (CLAUDE.md §8: "synchronize every
// asynchronous input... with a 2-FF synchronizer"), so a command that is
// held high for many cycles (e.g. a switch, not a one-shot pulse) still
// only fires ONCE, and a glitch can't double-fire it either.
//==========================================================================
module run_ctrl (
    input  logic clk,
    input  logic rst_n,       // async reset, active low

    input  logic run_set,     // level or pulse: rising edge -> RUN=1
    input  logic run_clear,   // level or pulse: rising edge -> RUN=0
    input  logic apply_cmd,   // level or pulse: rising edge -> one-cycle `apply` pulse

    output logic run,         // registered RUN level, broadcast to every cell
    output logic apply        // registered one-cycle APPLY strobe, broadcast to every cell
);

    // 2-FF synchronizers
    logic run_set_s0, run_set_s1;
    logic run_clear_s0, run_clear_s1;
    logic apply_cmd_s0, apply_cmd_s1;

    // previous-cycle value of each synchronized command, for edge detection
    logic run_set_s1_d, run_clear_s1_d, apply_cmd_s1_d;

    wire run_set_rise   = run_set_s1   && !run_set_s1_d;
    wire run_clear_rise = run_clear_s1 && !run_clear_s1_d;
    wire apply_cmd_rise = apply_cmd_s1 && !apply_cmd_s1_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_set_s0   <= 1'b0; run_set_s1   <= 1'b0; run_set_s1_d   <= 1'b0;
            run_clear_s0 <= 1'b0; run_clear_s1 <= 1'b0; run_clear_s1_d <= 1'b0;
            apply_cmd_s0 <= 1'b0; apply_cmd_s1 <= 1'b0; apply_cmd_s1_d <= 1'b0;
            run   <= 1'b0;
            apply <= 1'b0;
        end else begin
            run_set_s0   <= run_set;   run_set_s1   <= run_set_s0;   run_set_s1_d   <= run_set_s1;
            run_clear_s0 <= run_clear; run_clear_s1 <= run_clear_s0; run_clear_s1_d <= run_clear_s1;
            apply_cmd_s0 <= apply_cmd; apply_cmd_s1 <= apply_cmd_s0; apply_cmd_s1_d <= apply_cmd_s1;

            apply <= apply_cmd_rise;  // exactly one cycle per command edge, regardless of command pulse width

            if (run_clear_rise)      run <= 1'b0;   // STOP takes priority over a simultaneous run_set
            else if (run_set_rise)   run <= 1'b1;
        end
    end

endmodule
