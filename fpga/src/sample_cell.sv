`timescale 1ns / 1ps
//==========================================================================
// sample_cell
//
// Verification plan 2026-11-01 Step 3 (docs/plan_2026-11-01_verification.md):
// a small logic analyser inside the FPGA. Records N already-synchronized
// pins into a block-RAM ring, at a configurable rate, around a trigger,
// and lets the link read the record back after the run.
//
//   pins -> 2-FF sync (external, upstream, CLAUDE.md §8) -> sample_cell
//        -> ring buffer (DEPTH x N, block RAM) -> rd_idx / rd_data -> link
//
// Timing:
//   - One sample every cfg_div ticks (cfg_div = 1: every 10 ns tick; 0 is
//     treated as 1). The first sample is taken on the first tick after run
//     rises. Sample k is the pins' value at tick k*cfg_div after arming
//     (plus the upstream synchronizer's 2 ticks).
//   - The trigger is judged between consecutive SAMPLES (not ticks), so its
//     resolution is one sample period, the same as the record's:
//       TRIG_NOW    the first sample is the trigger (pre-trigger = 0)
//       TRIG_EXT    the first sample after a trig_ext strobe (e.g. a
//                   sequencer step start); the strobe is remembered
//       TRIG_RISE / TRIG_FALL   pin cfg_trig_pin 0->1 / 1->0 between samples
//       TRIG_HIGH / TRIG_LOW    pin cfg_trig_pin is 1 / 0 in a sample
//
// Record:
//   - Before the trigger (PRE) it records continuously into the ring and
//     keeps up to cfg_pre samples; the trigger sample and the samples after
//     it (POST) make up the rest, cfg_n samples in all, then DONE and the
//     writing stops. If the trigger comes before cfg_pre samples exist, the
//     record is shorter at the front (pre_got < cfg_pre).
//   - Requires 1 <= cfg_n <= DEPTH and cfg_pre < cfg_n (the PC checks this;
//     here cfg_n is clamped to 1..DEPTH and the post part to >= 1).
//   - run falling stops the recording and KEEPS the data; the next run
//     rising edge re-arms (clears the record). apply latches the config as
//     PENDING; it is taken at the next arming, so a record is always made
//     with one config (a mid-run apply neither erases nor changes it).
//
// Readout:
//   - rd_idx is a LOGICAL index: 0 = the oldest kept sample. The cell adds
//     the start address (DEPTH is a power of 2, so it simply wraps).
//     rd_data is valid one clock after rd_idx (block RAM read latency, the
//     same 1-tick latency as link_frame's byte bus).
//   - n_valid = samples in the record, trig_idx = logical index of the
//     trigger sample (= pre_got), flags armed / triggered / done.
//   - trig_count = samples taken since arming when the trigger sample was
//     taken (0 = the first one; saturates). So logical sample i was taken
//     (trig_count - trig_idx + i) * cfg_div + 1 ticks after run rose: the PC
//     puts the record on the same time axis as the expected waves.
//   - Reading while recording is allowed but returns a moving window.
//==========================================================================
module sample_cell #(
    parameter int N      = 32,     // pins per sample
    parameter int DEPTH  = 4096,   // samples in the ring (power of 2)
    parameter int TICK_W = 32
) (
    input  logic                     clk,
    input  logic                     rst_n,          // async reset, active low
    input  logic                     run,            // global RUN level (registered by run_ctrl / seq_engine)
    input  logic                     apply,          // one-cycle strobe: latch cfg_*

    input  logic [N-1:0]             sync_in,        // already 2-FF-synchronized pins

    input  logic [TICK_W-1:0]        cfg_div,        // ticks per sample (0 or 1 = every tick)
    input  logic [$clog2(DEPTH):0]   cfg_n,          // samples to record, 1..DEPTH
    input  logic [$clog2(DEPTH):0]   cfg_pre,        // of those, before the trigger, < cfg_n
    input  logic [2:0]               cfg_trig,       // TRIG_* below
    input  logic [$clog2(N > 1 ? N : 2)-1:0] cfg_trig_pin,

    input  logic                     trig_ext,       // one-cycle strobe for TRIG_EXT

    input  logic [$clog2(DEPTH)-1:0] rd_idx,         // logical read index (0 = oldest)
    output logic [N-1:0]             rd_data,        // valid 1 clock after rd_idx

    output logic                     armed,          // recording, waiting for the trigger
    output logic                     triggered,      // the trigger has been seen
    output logic                     done,           // the record is complete
    output logic [$clog2(DEPTH):0]   n_valid,        // samples in the record
    output logic [$clog2(DEPTH):0]   trig_idx,       // logical index of the trigger sample
    output logic [TICK_W-1:0]        trig_count      // samples since arming at the trigger sample
);

    localparam int AW = $clog2(DEPTH);
    localparam int PW = $clog2(N > 1 ? N : 2);

    localparam logic [2:0] TRIG_NOW  = 3'd0;
    localparam logic [2:0] TRIG_EXT  = 3'd1;
    localparam logic [2:0] TRIG_RISE = 3'd2;
    localparam logic [2:0] TRIG_FALL = 3'd3;
    localparam logic [2:0] TRIG_HIGH = 3'd4;
    localparam logic [2:0] TRIG_LOW  = 3'd5;

    localparam logic [AW:0] DEPTH_V = DEPTH;
    localparam logic [AW:0] ONE     = 1;

    // the ring must wrap by itself (simulation check; synthesis just uses AW bits)
    // synthesis translate_off
    initial if ((1 << AW) != DEPTH) $display("ERROR: sample_cell DEPTH=%0d is not a power of 2", DEPTH);
    // synthesis translate_on

    // ---- config: p_* latched on apply, a_* taken from p_* when a record is armed ----
    logic [TICK_W-1:0] p_div,  a_div;
    logic [AW:0]       p_n,    a_n, p_pre, a_pre;
    logic [2:0]        p_trig, a_trig;
    logic [PW-1:0]     p_pin,  a_pin;

    // ---- recording state ----
    logic              run_d;          // previous run, for the arming edge
    logic              rec;            // writing samples (armed or post-trigger)
    logic [TICK_W-1:0] div_cnt;        // ticks until the next sample
    logic [AW-1:0]     wr_addr;        // next ring address to write
    logic [AW:0]       pre_got;        // pre-trigger samples kept (<= a_pre)
    logic [AW:0]       post_got;       // samples from the trigger on
    logic [AW-1:0]     trig_addr;      // ring address of the trigger sample
    logic              ext_seen;       // trig_ext strobe remembered until the next sample
    logic              have_prev;      // a previous sample exists (for edge triggers)
    logic [N-1:0]      prev;           // the previous sample
    logic [TICK_W-1:0] n_taken;        // samples taken since arming (saturating)

    // ---- ring buffer (block RAM: one write port, one registered read port) ----
    (* ram_style = "block" *) logic [N-1:0] mem [0:DEPTH-1];
    logic              we;
    logic [AW-1:0]     rd_addr;

    wire sample_now = rec && (div_cnt == '0);

    // trigger judged on this sample (sync_in) against the previous one
    logic hit;
    always_comb begin
        case (a_trig)
            TRIG_NOW:  hit = 1'b1;
            TRIG_EXT:  hit = ext_seen || trig_ext;
            TRIG_RISE: hit = have_prev && !prev[a_pin] &&  sync_in[a_pin];
            TRIG_FALL: hit = have_prev &&  prev[a_pin] && !sync_in[a_pin];
            TRIG_HIGH: hit =  sync_in[a_pin];
            TRIG_LOW:  hit = !sync_in[a_pin];
            default:   hit = 1'b0;
        endcase
    end

    // post samples needed including the trigger sample: n - pre, at least 1
    wire [AW:0] post_need = (a_pre >= a_n) ? ONE : (a_n - a_pre);

    assign we = sample_now;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_div     <= '0;
            p_n       <= ONE;
            p_pre     <= '0;
            p_trig    <= TRIG_NOW;
            p_pin     <= '0;
            a_div     <= '0;
            a_n       <= ONE;
            a_pre     <= '0;
            a_trig    <= TRIG_NOW;
            a_pin     <= '0;
            run_d     <= 1'b0;
            rec       <= 1'b0;
            div_cnt   <= '0;
            wr_addr   <= '0;
            pre_got   <= '0;
            post_got  <= '0;
            trig_addr <= '0;
            ext_seen  <= 1'b0;
            have_prev <= 1'b0;
            prev      <= '0;
            n_taken   <= '0;
            trig_count <= '0;
            armed     <= 1'b0;
            triggered <= 1'b0;
            done      <= 1'b0;
        end else begin
            run_d <= run;

            if (apply) begin
                p_div  <= cfg_div;
                // clamp n to 1..DEPTH (the PC checks it; this keeps the ring safe)
                p_n    <= (cfg_n == '0) ? ONE : (cfg_n > DEPTH_V) ? DEPTH_V : cfg_n;
                p_pre  <= cfg_pre;
                p_trig <= cfg_trig;
                p_pin  <= cfg_trig_pin;
            end

            if (run && !run_d) begin
                // arm with the pending config: clear the record, first sample on the next tick
                a_div     <= p_div;
                a_n       <= p_n;
                a_pre     <= p_pre;
                a_trig    <= p_trig;
                a_pin     <= p_pin;
                rec       <= 1'b1;
                div_cnt   <= '0;
                wr_addr   <= '0;
                pre_got   <= '0;
                post_got  <= '0;
                trig_addr <= '0;
                ext_seen  <= 1'b0;
                have_prev <= 1'b0;
                n_taken   <= '0;
                trig_count <= '0;
                armed     <= 1'b1;
                triggered <= 1'b0;
                done      <= 1'b0;
            end else if (!run) begin
                rec   <= 1'b0;           // stop, keep the data
                armed <= 1'b0;
            end else if (rec) begin
                if (trig_ext) ext_seen <= 1'b1;
                if (sample_now) begin
                    div_cnt   <= (a_div > 1) ? a_div - 1'b1 : '0;
                    wr_addr   <= wr_addr + 1'b1;
                    prev      <= sync_in;
                    have_prev <= 1'b1;
                    ext_seen  <= 1'b0;
                    if (~n_taken != '0) n_taken <= n_taken + 1'b1;
                    if (!triggered && hit) begin
                        triggered <= 1'b1;
                        trig_count <= n_taken;
                        armed     <= 1'b0;
                        trig_addr <= wr_addr;
                        post_got  <= ONE;
                        if (post_need == ONE) begin
                            rec  <= 1'b0;
                            done <= 1'b1;
                        end
                    end else if (!triggered) begin
                        if (pre_got < a_pre) pre_got <= pre_got + 1'b1;
                    end else begin
                        post_got <= post_got + 1'b1;
                        if (post_got + 1'b1 == post_need) begin
                            rec  <= 1'b0;
                            done <= 1'b1;
                        end
                    end
                end else begin
                    div_cnt <= div_cnt - 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (we) mem[wr_addr] <= sync_in;
    end

    // oldest kept sample: pre_got samples before the trigger, or (still armed)
    // before the next write address
    wire [AW-1:0] first_addr = (triggered ? trig_addr : wr_addr) - pre_got[AW-1:0];
    assign rd_addr = first_addr + rd_idx;

    always_ff @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

    assign n_valid  = pre_got + post_got;
    assign trig_idx = pre_got;

endmodule
