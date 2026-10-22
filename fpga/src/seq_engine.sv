`timescale 1ns / 1ps
//==========================================================================
// seq_engine
//
// generic_controller_prompt.md §3 Phase 7: runs a mode as an ordered list
// of steps. Each step = new config for some cells + an end condition
// (fixed tick count, or wait for a cell event with a timeout). The step
// table itself lives outside (compile-time package in Phase 7's loopback
// top, a link-written RAM later): this engine outputs `step` and reads that
// step's entry back on the step_* inputs, so the same engine works with
// either.
//
// Plan (CLAUDE.md §8: steps first):
//   1. PRELOAD (after reset, once): APPLY every cell with step 0's config,
//      RUN low -> every pin sits at step 0's idle level before anything
//      runs (instead of sig_cell's reset value 0).
//   2. IDLE: wait for `start`.
//   3. FIRST: APPLY every cell with step 0 (RUN still low), then raise RUN.
//      Every cell starts on the same tick (architecture rule).
//   4. RUNNING: count ticks in this step. At the end of the step either
//      finish (last step) or APPLY only the next step's masked cells, with
//      RUN staying high: cells not in the mask keep running untouched; a
//      masked cell restarts on that tick (sig_cell/cap_cell's atomic apply),
//      so its delay counts from the step's start.
//   5. Ending (last step done / timeout fault / abort): RUN low and APPLY
//      step 0 to every cell in the same tick -> pins go to idle, then to
//      step 0's idle levels. seq_done / fault / aborted stay set until the
//      next start; last_step says where it ended.
//
// Timing contract (checked by fpga/tb/seq_engine_tb.sv):
//   * apply strobes of consecutive steps are exactly `cond_arg` ticks apart
//     for a COND_AFTER step (cond_arg >= 1);
//   * a wait step ends the tick after its condition is seen; conditions are
//     ignored while step_cnt < 2 (a re-armed cap_cell clears its counter
//     one tick after APPLY, and a re-applied sig_cell may still emit its old
//     config's done strobe on that tick), so a condition that is already
//     true ends the step on its 3rd tick;
//   * a wait step whose condition hasn't been seen after `timeout` ticks
//     (step_cnt == timeout) FAULTs. timeout = 0 means "no timeout" (the
//     Python compiler never emits that for a wait step).
//
// Every output is registered except sig_apply/cap_apply, which are a
// registered one-cycle pulse ANDed with the current step's mask (both
// registered/constant). They only feed cell `apply` inputs, never a pin.
//==========================================================================
module seq_engine #(
    parameter int N_SIG  = 5,
    parameter int N_CAP  = 5,
    parameter int TICK_W = 32,
    parameter int STEP_W = 4     // up to 2**STEP_W steps
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    start,        // 1-cycle, already synchronized
    input  logic                    abort,        // 1-cycle, already synchronized
    input  logic [STEP_W:0]         n_steps,      // 1 .. 2**STEP_W

    // table entry of the current `step` (looked up outside, combinationally)
    input  logic [N_SIG-1:0]        step_sig_mask,
    input  logic [N_CAP-1:0]        step_cap_mask,
    input  logic [2:0]              step_cond,     // COND_*
    input  logic [7:0]              step_cond_cell,
    input  logic [TICK_W-1:0]       step_cond_arg, // AFTER: ticks; EDGES: count; LEVEL: value
    input  logic [TICK_W-1:0]       step_timeout,

    // cell feedback
    input  logic [N_SIG-1:0]        sig_done,
    input  logic [N_CAP-1:0]        cap_done,
    input  logic [N_CAP-1:0]        cap_level,
    input  logic [N_CAP*TICK_W-1:0] cap_edges,

    output logic [STEP_W-1:0]       step,
    output logic                    run,
    output logic [N_SIG-1:0]        sig_apply,
    output logic [N_CAP-1:0]        cap_apply,
    output logic                    busy,
    output logic                    seq_done,
    output logic                    fault,
    output logic                    aborted,
    output logic [STEP_W-1:0]       last_step,
    output logic                    step_start     // 1-cycle, same cycle as a step's apply
);

    localparam logic [2:0] COND_AFTER    = 3'd0;
    localparam logic [2:0] COND_DONE     = 3'd1;  // sig_done[cell]
    localparam logic [2:0] COND_CAPTURED = 3'd2;  // cap_done[cell]
    localparam logic [2:0] COND_EDGES    = 3'd3;  // cap_edges[cell] >= arg
    localparam logic [2:0] COND_LEVEL    = 3'd4;  // cap_level[cell] == arg[0]

    typedef enum logic [2:0] {S_PRELOAD, S_IDLE, S_FIRST, S_RUNNING} state_t;
    state_t state;

    logic [TICK_W-1:0] step_cnt;     // ticks since this step's apply (0 in the apply cycle)
    logic              apply_pulse;  // one-cycle
    logic              apply_all;    // with apply_pulse: every cell, not just the mask

    assign sig_apply = apply_pulse ? (apply_all ? {N_SIG{1'b1}} : step_sig_mask) : '0;
    assign cap_apply = apply_pulse ? (apply_all ? {N_CAP{1'b1}} : step_cap_mask) : '0;
    assign step_start = apply_pulse && (state == S_FIRST || state == S_RUNNING);
    assign busy = (state == S_FIRST) || (state == S_RUNNING);

    // ---- end-of-step condition for the current step ----
    logic [TICK_W-1:0] edges_sel;
    assign edges_sel = cap_edges[step_cond_cell*TICK_W +: TICK_W];

    logic cond_met;
    always_comb begin
        case (step_cond)
            COND_AFTER:    cond_met = (step_cnt == step_cond_arg - 1'b1);
            COND_DONE:     cond_met = (step_cnt >= 2) && sig_done[step_cond_cell];
            COND_CAPTURED: cond_met = (step_cnt >= 2) && cap_done[step_cond_cell];
            COND_EDGES:    cond_met = (step_cnt >= 2) && (edges_sel >= step_cond_arg);
            COND_LEVEL:    cond_met = (step_cnt >= 2) && (cap_level[step_cond_cell] == step_cond_arg[0]);
            default:       cond_met = 1'b0;
        endcase
    end

    logic timed_out;
    assign timed_out = (step_cond != COND_AFTER) && (step_timeout != '0)
                       && (step_cnt == step_timeout) && !cond_met;

    logic last;
    assign last = ({1'b0, step} == n_steps - 1'b1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_PRELOAD;
            step        <= '0;
            step_cnt    <= '0;
            run         <= 1'b0;
            apply_pulse <= 1'b0;
            apply_all   <= 1'b0;
            seq_done    <= 1'b0;
            fault       <= 1'b0;
            aborted     <= 1'b0;
            last_step   <= '0;
        end else begin
            apply_pulse <= 1'b0;
            apply_all   <= 1'b0;
            step_cnt    <= step_cnt + 1'b1;

            case (state)
                S_PRELOAD: begin
                    // step is 0 since reset: step 0's config is on the step_* bus
                    apply_pulse <= 1'b1;
                    apply_all   <= 1'b1;
                    state       <= S_IDLE;
                end

                S_IDLE: begin
                    if (start) begin
                        seq_done    <= 1'b0;
                        fault       <= 1'b0;
                        aborted     <= 1'b0;
                        step        <= '0;
                        step_cnt    <= '0;      // 0 in the apply cycle
                        apply_pulse <= 1'b1;
                        apply_all   <= 1'b1;
                        state       <= S_FIRST;
                    end
                end

                S_FIRST: begin
                    // this is step 0's apply cycle (RUN still low); RUN rises next
                    run   <= 1'b1;
                    state <= S_RUNNING;
                    if (abort) begin
                        run       <= 1'b0;
                        aborted   <= 1'b1;
                        last_step <= step;
                        apply_pulse <= 1'b1;
                        apply_all   <= 1'b1;
                        state     <= S_IDLE;
                    end else if (cond_met && step_cond == COND_AFTER) begin
                        // a 1-tick step 0: end it here too, so AFTER stays exact
                        if (last) begin
                            run       <= 1'b0;
                            seq_done  <= 1'b1;
                            last_step <= step;
                            apply_pulse <= 1'b1;
                            apply_all   <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            step        <= step + 1'b1;
                            step_cnt    <= '0;
                            apply_pulse <= 1'b1;
                        end
                    end
                end

                S_RUNNING: begin
                    if (abort || timed_out || (cond_met && last)) begin
                        run         <= 1'b0;
                        last_step   <= step;
                        aborted     <= abort;
                        fault       <= !abort && timed_out;
                        seq_done    <= !abort && !timed_out;
                        step        <= '0;      // step 0 back on the bus for the re-apply
                        apply_pulse <= 1'b1;
                        apply_all   <= 1'b1;
                        state       <= S_IDLE;
                    end else if (cond_met) begin
                        step        <= step + 1'b1;
                        step_cnt    <= '0;
                        apply_pulse <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
