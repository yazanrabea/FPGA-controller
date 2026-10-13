`timescale 1ns / 1ps
//==========================================================================
// cap_cell
//
// One generic, config-driven capture cell -- one instance per FPGA input
// pin (chip output), per generic_controller_prompt.md's architecture:
//   chip output -> 2-FF sync (external, upstream of this cell) -> cap_cell
//   -> status registers -> link TX.
//
// `sync_in` is assumed ALREADY passed through a 2-FF synchronizer upstream
// (CLAUDE.md §8: "synchronize every asynchronous input") -- this cell only
// adds the one extra register every mode here needs anyway to detect edges
// (comparing a value to its own previous cycle), not a second synchronizer.
//
// Modes (generic_controller_prompt.md §1 item 6):
//   LEVEL      - level_out mirrors sync_in, one cycle late.
//   EDGE_COUNT - counts rising edges of sync_in while running.
//   PERIOD     - measures ticks between consecutive rising edges (period)
//                and between a rising edge and the next falling edge (high
//                time) -- e.g. for a frequency/duty check on dft0_buff /
//                dft1_buff (CLAUDE.md §7's eventual phi1/phi2 check).
//   SERIAL     - shifts sync_in into capture_reg once per `capture_strobe`
//                pulse (meant to be wired, at Phase 4 top-level integration,
//                to another cell's rising/falling edge output -- the same
//                pattern as sig_cell's SERIAL `shift_strobe`), for N-bit
//                captures like piso_out's 168-bit frame.
//
//                Alignment note: msb_first shifts left (new bit enters at
//                bit 0), lsb_first shifts right (new bit enters at the top
//                bit). When cfg_bits == CAP_W (the normal case -- size
//                CAP_W to exactly match the real capture width) both modes
//                leave the result at capture_reg[CAP_W-1:0] in natural
//                binary order. Only if cfg_bits < CAP_W (a partial/test
//                capture) do the two modes land in different halves of the
//                register: msb_first at the bottom [cfg_bits-1:0], lsb_first
//                at the top [CAP_W-1:CAP_W-cfg_bits] -- a consequence of
//                which end each mode shifts from, not a bug, but something
//                a consumer reading a partial capture needs to know.
//
// Same atomic-apply convention as sig_cell: `apply` latches cfg_mode into
// active_mode and resets every internal counter/register, so switching
// capture mode while running restarts cleanly rather than blending old and
// new measurements.
//==========================================================================
module cap_cell #(
    parameter int TICK_W = 32,   // width of every tick-counting / count register
    parameter int CAP_W  = 8     // width of the SERIAL capture register
) (
    input  logic                clk,
    input  logic                rst_n,          // async reset, active low
    input  logic                run,            // global RUN level (synchronized/registered by run_ctrl)
    input  logic                apply,          // global one-cycle APPLY strobe (synchronized by run_ctrl)

    input  logic                sync_in,        // already 2-FF-synchronized chip output

    input  logic [1:0]          cfg_mode,       // 0=LEVEL,1=EDGE_COUNT,2=PERIOD,3=SERIAL
    input  logic                cfg_msb_first,  // SERIAL: bit order capture_reg is packed in
    input  logic [TICK_W-1:0]   cfg_bits,       // SERIAL: number of bits to capture (<= CAP_W)

    input  logic                capture_strobe, // SERIAL: external one-cycle bit-advance strobe

    output logic                level_out,          // LEVEL: registered mirror of sync_in
    output logic [TICK_W-1:0]   edge_count,         // EDGE_COUNT: rising edges seen since run/apply
    output logic [TICK_W-1:0]   period_ticks,       // PERIOD: last measured period, in ticks
    output logic [TICK_W-1:0]   high_ticks,         // PERIOD: last measured high time, in ticks
    output logic                period_valid,       // PERIOD: 1-cycle pulse, a new period_ticks is ready
    output logic [CAP_W-1:0]    capture_reg,        // SERIAL: captured bits
    output logic                done                // SERIAL: 1-cycle pulse, cfg_bits captured
);

    localparam logic [1:0] MODE_LEVEL      = 2'd0;
    localparam logic [1:0] MODE_EDGE_COUNT = 2'd1;
    localparam logic [1:0] MODE_PERIOD     = 2'd2;
    localparam logic [1:0] MODE_SERIAL     = 2'd3;

    logic [1:0]        active_mode;
    logic              active_msb_first;
    logic [TICK_W-1:0] active_bits;

    logic sync_in_d;          // previous-cycle value, for edge detection
    logic rise, fall;

    logic [TICK_W-1:0] free_tick;      // free-running tick counter while run (for PERIOD timing)
    logic [TICK_W-1:0] last_rise_tick;
    logic              have_rise;      // seen at least one rising edge since run/apply (for PERIOD)

    logic [TICK_W-1:0] bit_cnt;        // SERIAL: bits captured so far
    logic              bits_done;

    assign rise = run && sync_in && !sync_in_d;
    assign fall = run && !sync_in && sync_in_d;
    assign bits_done = (bit_cnt >= active_bits);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_mode      <= MODE_LEVEL;
            active_msb_first <= 1'b1;
            active_bits      <= '0;

            sync_in_d    <= 1'b0;
            level_out    <= 1'b0;
            edge_count   <= '0;
            free_tick    <= '0;
            last_rise_tick <= '0;
            have_rise    <= 1'b0;
            period_ticks <= '0;
            high_ticks   <= '0;
            period_valid <= 1'b0;
            bit_cnt      <= '0;
            capture_reg  <= '0;
            done         <= 1'b0;
        end else begin
            sync_in_d <= sync_in;
            level_out <= sync_in;
            period_valid <= 1'b0;
            done         <= 1'b0;

            if (apply) begin
                active_mode      <= cfg_mode;
                active_msb_first <= cfg_msb_first;
                active_bits      <= cfg_bits;

                edge_count     <= '0;
                free_tick      <= '0;
                last_rise_tick <= '0;
                have_rise      <= 1'b0;
                period_ticks   <= '0;
                high_ticks     <= '0;
                bit_cnt        <= '0;
                capture_reg    <= '0;
            end else if (!run) begin
                edge_count     <= '0;
                free_tick      <= '0;
                last_rise_tick <= '0;
                have_rise      <= 1'b0;
                bit_cnt        <= '0;
            end else begin
                free_tick <= free_tick + 1'b1;

                case (active_mode)
                    MODE_EDGE_COUNT: begin
                        if (rise) edge_count <= edge_count + 1'b1;
                    end
                    MODE_PERIOD: begin
                        if (rise) begin
                            if (have_rise) begin
                                period_ticks <= free_tick - last_rise_tick;
                                period_valid <= 1'b1;
                            end
                            last_rise_tick <= free_tick;
                            have_rise      <= 1'b1;
                        end
                        if (fall && have_rise) begin
                            high_ticks <= free_tick - last_rise_tick;
                        end
                    end
                    MODE_SERIAL: begin
                        if (!bits_done && capture_strobe) begin
                            bit_cnt     <= bit_cnt + 1'b1;
                            capture_reg <= active_msb_first
                                           ? {capture_reg[CAP_W-2:0], sync_in}
                                           : {sync_in, capture_reg[CAP_W-1:1]};
                            if (bit_cnt == active_bits - 1) done <= 1'b1;
                        end
                    end
                    default: ; // MODE_LEVEL: nothing extra, level_out already updated above
                endcase
            end
        end
    end

endmodule
