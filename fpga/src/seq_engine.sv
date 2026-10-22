`timescale 1ns / 1ps
//==========================================================================
// seq_engine
//
// generic_controller_prompt.md §3 Phase 7: runs a mode as an ordered list
// of steps. Each step = new config for some cells + an end condition
// (fixed tick count, or wait for a cell event with a timeout). The step
// table lives outside: a compile-time package (phase7_seq_loopback_top) or
// a link-written RAM with a prefetched "next step" bank (seq_bank.sv,
// phase7_link_top). The engine says which step it wants (`step` for the
// current one, `fetch_step` for the one the bank should hold next) and is
// told when that one is there (`fetch_ready`). A package top ties
// fetch_ready = 1 (every step is always available).
//
// Plan (CLAUDE.md §8: steps first):
//   1. PRELOAD (after reset): wait until step 0 is fetched, APPLY every
//      cell with it, RUN low -> every pin sits at step 0's idle level before
//      anything runs (instead of sig_cell's reset value 0). `preload` (a
//      1-tick input, IDLE only) does the same again on request, e.g. after
//      the PC wrote a new table.
//   2. IDLE: wait for `start` (a START that arrives while step 0 is being
//      (re)loaded is remembered and runs as soon as IDLE is reached).
//   3. FIRST: with step 0 fetched, APPLY every cell with it (RUN still
//      low), then raise RUN. Every cell starts on the same tick. The bank
//      is asked for step 1 on that same apply tick.
//   4. RUNNING: count ticks in this step. At the end of the step either
//      finish (last step) or, if the next step is fetched, APPLY only its
//      masked cells, RUN staying high: cells not in the mask keep running
//      untouched; a masked cell restarts on that tick, so its delay counts
//      from the step's start. If the next step is NOT fetched yet (a step
//      shorter than the bank's copy time), WAIT for it and set the sticky
//      `late` flag: that boundary was not tick-exact.
//   5. Ending (last step done / timeout fault / abort): RUN low at once;
//      then, once step 0 is fetched again, APPLY it to every SIG cell ->
//      pins go to idle, then to step 0's idle levels. Cap cells are NOT
//      re-applied, so captured results (capture_reg) survive for the PC to
//      read until the next start (cap_cell itself still clears its edge
//      counters when RUN drops, by its Phase 3 design). seq_done / fault /
//      aborted / late stay set until the next start; last_step says where
//      it ended.
//
// Timing contract (checked by fpga/tb/seq_engine_tb.sv):
//   * apply strobes of consecutive steps are exactly `cond_arg` ticks apart
//     for a COND_AFTER step (cond_arg >= 1), as long as the next step is
//     fetched in time (always, with fetch_ready = 1); otherwise the next
//     apply comes the tick after fetch_ready and `late` is set;
//   * a wait step ends the tick after its condition is seen (same proviso);
//     conditions are ignored while step_cnt < 2 (a re-armed cap_cell clears
//     its counter one tick after APPLY, and a re-applied sig_cell may still
//     emit its old config's done strobe on that tick), so a condition that
//     is already true ends the step on its 3rd tick;
//   * a wait step whose condition hasn't been seen after `timeout` ticks
//     (step_cnt == timeout) FAULTs. timeout = 0 means "no timeout" (the
//     Python compiler never emits that for a wait step).
//
// The step_* inputs describe `step` except on an apply tick, where they
// must already describe the step being applied (seq_bank.sv does this by
// showing the next bank on apply_tick; a package top indexes by `step`,
// which is already the new step then).
//
// Every output is registered except sig_apply/cap_apply, which are a
// registered one-cycle pulse ANDed with the current step's mask. They only
// feed cell `apply` inputs, never a pin.
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
    input  logic                    preload,      // 1-cycle: re-apply step 0 with RUN low (IDLE only)
    input  logic [STEP_W:0]         n_steps,      // 1 .. 2**STEP_W

    // table entry of the current `step` (see header for the apply tick)
    input  logic [N_SIG-1:0]        step_sig_mask,
    input  logic [N_CAP-1:0]        step_cap_mask,
    input  logic [2:0]              step_cond,     // COND_*
    input  logic [7:0]              step_cond_cell,
    input  logic [TICK_W-1:0]       step_cond_arg, // AFTER: ticks; EDGES: count; LEVEL: value
    input  logic [TICK_W-1:0]       step_timeout,

    // next-step bank handshake (tie fetch_ready = 1 when every step is always available)
    output logic [STEP_W-1:0]       fetch_step,
    input  logic                    fetch_ready,   // the bank holds fetch_step's entry

    // cell feedback
    input  logic [N_SIG-1:0]        sig_done,
    input  logic [N_CAP-1:0]        cap_done,
    input  logic [N_CAP-1:0]        cap_level,
    input  logic [N_CAP*TICK_W-1:0] cap_edges,

    output logic [STEP_W-1:0]       step,
    output logic                    run,
    output logic [N_SIG-1:0]        sig_apply,
    output logic [N_CAP-1:0]        cap_apply,
    output logic                    apply_tick,    // 1-cycle, any apply (incl. preload/reload)
    output logic                    busy,
    output logic                    seq_done,
    output logic                    fault,
    output logic                    aborted,
    output logic                    late,          // sticky: a boundary waited for the bank
    output logic [STEP_W-1:0]       last_step,
    output logic                    step_start     // 1-cycle, same cycle as a step's apply
);

    localparam logic [2:0] COND_AFTER    = 3'd0;
    localparam logic [2:0] COND_DONE     = 3'd1;  // sig_done[cell]
    localparam logic [2:0] COND_CAPTURED = 3'd2;  // cap_done[cell]
    localparam logic [2:0] COND_EDGES    = 3'd3;  // cap_edges[cell] >= arg
    localparam logic [2:0] COND_LEVEL    = 3'd4;  // cap_level[cell] == arg[0]

    typedef enum logic [2:0] {
        S_PRELOAD,   // waiting to apply step 0 (after reset or `preload`), RUN low
        S_IDLE,
        S_ARM,       // START seen, waiting for step 0
        S_FIRST,     // step 0's apply tick; RUN rises next
        S_RUNNING,
        S_WAIT,      // step ended, waiting for the next step's fetch (late)
        S_RELOAD     // sequence over, RUN low, waiting to re-apply step 0 to sig cells
    } state_t;
    state_t state;

    logic [TICK_W-1:0] step_cnt;     // ticks since this step's apply (0 in the apply cycle)
    logic [TICK_W-1:0] step_cnt1;    // always step_cnt + 1, kept in its own register: COND_AFTER
                                     // compares it with the arg instead of step_cnt with arg - 1,
                                     // which took a 32-bit subtract off the late hdr path
                                     // (phase7_link_jtag_top missed 100 MHz by 0.037 ns, docs/issues.md)
    logic              apply_pulse;  // one-cycle
    logic              apply_all;    // with apply_pulse: every sig cell, not just the mask
    logic              apply_caps;   // with apply_all: every cap cell too (not at the end)
    logic              start_q;      // START seen during PRELOAD/RELOAD: run it once IDLE

    assign sig_apply = apply_pulse ? (apply_all ? {N_SIG{1'b1}} : step_sig_mask) : '0;
    assign cap_apply = apply_pulse ? (apply_all ? (apply_caps ? {N_CAP{1'b1}} : '0)
                                                : step_cap_mask) : '0;
    assign apply_tick = apply_pulse;
    assign step_start = apply_pulse && (state == S_FIRST || state == S_RUNNING);
    assign busy = (state == S_ARM) || (state == S_FIRST) || (state == S_RUNNING) || (state == S_WAIT);

    // ---- end-of-step condition for the current step ----
    logic [TICK_W-1:0] edges_sel;
    assign edges_sel = cap_edges[step_cond_cell*TICK_W +: TICK_W];

    logic cond_met;
    always_comb begin
        case (step_cond)
            COND_AFTER:    cond_met = (step_cnt1 == step_cond_arg);   // = (step_cnt == arg - 1)
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

    // the step after next, for the bank, while one is still left
    logic [STEP_W-1:0] after_next;
    assign after_next = ({1'b0, step} + 2 < n_steps) ? step + 2'd2 : step + 1'b1;

    // next step ready on the bank right now (fetch_step is always step+1 while running)
    logic next_ready;
    assign next_ready = fetch_ready && (fetch_step == step + 1'b1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_PRELOAD;
            step        <= '0;
            fetch_step  <= '0;
            step_cnt    <= '0;  step_cnt1 <= TICK_W'(1);
            run         <= 1'b0;
            apply_pulse <= 1'b0;
            apply_all   <= 1'b0;
            apply_caps  <= 1'b0;
            start_q     <= 1'b0;
            seq_done    <= 1'b0;
            fault       <= 1'b0;
            aborted     <= 1'b0;
            late        <= 1'b0;
            last_step   <= '0;
        end else begin
            apply_pulse <= 1'b0;
            apply_all   <= 1'b0;
            apply_caps  <= 1'b0;
            step_cnt    <= step_cnt + 1'b1;
            step_cnt1   <= step_cnt1 + 1'b1;
            // A START during the (re)load of step 0 isn't lost: it runs as soon as IDLE.
            // An ABORT cancels it. Outside those states START means what it always did
            // (ignored while busy).
            if ((state == S_PRELOAD || state == S_RELOAD) && start) start_q <= 1'b1;
            if (abort) start_q <= 1'b0;

            case (state)
                S_PRELOAD: if (fetch_ready) begin   // fetch_step / step are 0 here
                    apply_pulse <= 1'b1;
                    apply_all   <= 1'b1;
                    apply_caps  <= 1'b1;
                    state       <= S_IDLE;
                end

                S_IDLE: begin
                    if (start || start_q) begin
                        start_q  <= 1'b0;
                        seq_done <= 1'b0;
                        fault    <= 1'b0;
                        aborted  <= 1'b0;
                        late     <= 1'b0;
                        step     <= '0;
                        state    <= S_ARM;
                        if (fetch_ready) begin       // step 0 already there: apply now
                            step_cnt    <= '0;  step_cnt1 <= TICK_W'(1);       // 0 in the apply cycle
                            apply_pulse <= 1'b1;
                            apply_all   <= 1'b1;
                            apply_caps  <= 1'b1;
                            fetch_step  <= (n_steps > 1) ? 1 : 0;
                            state       <= S_FIRST;
                        end
                    end else if (preload) begin
                        state <= S_PRELOAD;
                    end
                end

                S_ARM: begin
                    if (abort) begin
                        aborted   <= 1'b1;
                        last_step <= step;
                        state     <= S_RELOAD;
                    end else if (fetch_ready) begin
                        step_cnt    <= '0;  step_cnt1 <= TICK_W'(1);
                        apply_pulse <= 1'b1;
                        apply_all   <= 1'b1;
                        apply_caps  <= 1'b1;
                        fetch_step  <= (n_steps > 1) ? 1 : 0;
                        state       <= S_FIRST;
                    end
                end

                S_FIRST: begin
                    // step 0's apply tick (RUN still low); RUN rises next. fetch_step already
                    // asks for step 1: requested on this same tick, the bank only starts
                    // overwriting its contents on the next one, after the cells latched step 0.
                    run        <= 1'b1;
                    state      <= S_RUNNING;
                    if (abort) begin
                        run        <= 1'b0;
                        aborted    <= 1'b1;
                        last_step  <= step;
                        fetch_step <= '0;
                        state      <= S_RELOAD;
                    end else if (cond_met && step_cond == COND_AFTER) begin
                        // a 1-tick step 0: end it here too, so AFTER stays exact
                        if (last) begin
                            run        <= 1'b0;
                            seq_done   <= 1'b1;
                            last_step  <= step;
                            fetch_step <= '0;
                            state      <= S_RELOAD;
                        end else if (next_ready) begin
                            step        <= step + 1'b1;
                            step_cnt    <= '0;  step_cnt1 <= TICK_W'(1);
                            apply_pulse <= 1'b1;
                            fetch_step  <= after_next;
                        end else begin
                            late  <= 1'b1;
                            state <= S_WAIT;
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
                        fetch_step  <= '0;
                        state       <= S_RELOAD;
                    end else if (cond_met) begin
                        if (next_ready) begin
                            step        <= step + 1'b1;
                            step_cnt    <= '0;  step_cnt1 <= TICK_W'(1);
                            apply_pulse <= 1'b1;
                            fetch_step  <= after_next;
                        end else begin
                            late  <= 1'b1;      // this boundary can't be tick-exact
                            state <= S_WAIT;
                        end
                    end
                end

                S_WAIT: begin
                    if (abort) begin
                        run        <= 1'b0;
                        last_step  <= step;
                        aborted    <= 1'b1;
                        step       <= '0;
                        fetch_step <= '0;
                        state      <= S_RELOAD;
                    end else if (next_ready) begin
                        step        <= step + 1'b1;
                        step_cnt    <= '0;  step_cnt1 <= TICK_W'(1);
                        apply_pulse <= 1'b1;
                        fetch_step  <= after_next;
                        state       <= S_RUNNING;
                    end
                end

                S_RELOAD: if (fetch_ready) begin    // step / fetch_step are 0 here
                    apply_pulse <= 1'b1;
                    apply_all   <= 1'b1;            // sig cells only: captures survive
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
