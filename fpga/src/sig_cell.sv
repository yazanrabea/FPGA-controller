`timescale 1ns / 1ps
//==========================================================================
// sig_cell
//
// One generic, config-driven signal generator cell -- one instance per FPGA
// output pin, per generic_controller_prompt.md's architecture:
//   shadow registers -> atomic APPLY -> active registers -> this cell
//   -> output FF -> FMC pin.
//
// Supports 5 of the config's 6 "LOW/HIGH/PULSE/CLOCK/SERIAL/BUS" setting
// types in hardware: LOW, HIGH, PULSE, CLOCK, SERIAL. BUS is deliberately
// NOT a hardware mode here: a BUS setting (tools/nemo_ctl/groups.py) is a
// group of ordinary pins sharing one user-typed value, decomposed into a
// plain LOW/HIGH per pin by the Python tool before it ever reaches a
// register -- there is nothing for the hardware to do differently for a
// "bus bit" than for any other LOW/HIGH pin. Giving sig_cell a 6th mode that
// behaves identically to LOW/HIGH would just be a dead, untestable state.
// (Flagged here per CLAUDE.md §2's "if you find a concrete reason to
// deviate, explain first" -- this is that explanation.)
//
// One rest level, two names for it: cfg_idle_level is the level this pin
// sits at (a) whenever !run, and (b) as the "low phase" of PULSE/CLOCK while
// running. The "high phase" (the pulse itself, or a clock's high time) is
// always the complement, ~cfg_idle_level. This is also why there is no
// separate "polarity" input: an active-low reset (idle HIGH, pulses LOW) and
// an active-high reset (idle LOW, pulses HIGH) are just cfg_idle_level=1 vs
// 0 -- the pin_db/wizard layer already resolves "polarity" into idle_level
// before it reaches hardware (see tools/nemo_ctl/gen_pin_db.py's
// PIN_METADATA), so there is no second field to carry the same information.
// LOW/HIGH are the one exception: they are literal constants while running,
// independent of idle_level (a pin idle HIGH can still be told "hold
// asserted/0 for this whole mode" via type=LOW -- that is a real, intended
// case, e.g. holding `shift`=0 throughout a PISO load).
//
// Atomic apply, including mid-run: `apply` latches the new active_* config
// AND resets every internal counter/shift-register to zero in the same
// cycle. That means a config change while running doesn't try to splice
// the new timing into the old phase (which would be ambiguous: what does
// "half-way through the old period" mean under a new period?) -- it cleanly
// restarts this cell's sequence as if RUN had just been asserted, under the
// new config. This is simple, deterministic, and exactly what the Phase 3
// testbench's "config change while running" case checks for.
//
// SERIAL mode does not time itself from the 100 MHz timebase: it shifts one
// bit per pulse of `shift_strobe`, an external one-cycle strobe meant to be
// wired (at Phase 4 top-level integration) to another sig_cell's
// rising_edge/falling_edge output -- e.g. sipo_in's shift_strobe <=
// clk_sipo's falling_edge, per docs/controller_spec.md §3's note that
// sipo_in must change on clk_sipo's falling edge. cfg_data must already be
// packed into the SERIAL_W-wide register MSB-justified (for msb_first) or
// LSB-justified (for !msb_first) by the software side; this cell only knows
// how to shift that register, not how to pack it.
//==========================================================================
module sig_cell #(
    parameter int TICK_W   = 32,   // width of every tick-counting register
    parameter int SERIAL_W = 8     // width of the SERIAL shift register
) (
    input  logic                clk,            // 100 MHz timebase; 1 clk cycle = 1 tick
    input  logic                rst_n,           // async reset, active low
    input  logic                run,             // global RUN level (already synchronized/registered by run_ctrl)
    input  logic                apply,           // global one-cycle APPLY strobe (already synchronized by run_ctrl)

    // shadow configuration: latched into the active_* registers on `apply`
    input  logic [2:0]          cfg_type,
    input  logic                cfg_idle_level,
    input  logic [TICK_W-1:0]   cfg_delay,        // ticks from RUN rising edge to first action
    input  logic [TICK_W-1:0]   cfg_param_a,      // CLOCK: period N (>=2)   | PULSE: width
    input  logic [TICK_W-1:0]   cfg_param_b,      // CLOCK: high time H      | PULSE: repeat period
    input  logic [TICK_W-1:0]   cfg_cycles,       // CLOCK: cycle count (0=free-running)
                                                   // PULSE: repeat count (0 or 1 = one-shot)
    input  logic                cfg_msb_first,    // SERIAL
    input  logic [SERIAL_W-1:0] cfg_data,         // SERIAL: pre-packed bit pattern
    input  logic [TICK_W-1:0]   cfg_bits,         // SERIAL: number of bits to send (<= SERIAL_W)

    input  logic                shift_strobe,     // SERIAL: external one-cycle bit-advance strobe

    output logic                pin_out,          // registered pin drive -- wire straight to the output FF/IOB
    output logic                rising_edge,      // 1-cycle strobe, same cycle pin_out becomes 1
    output logic                falling_edge,     // 1-cycle strobe, same cycle pin_out becomes 0
    output logic                active,           // 1 while delay has elapsed and cycles/bits aren't exhausted
    output logic                done              // 1-cycle strobe: cycles/bits just exhausted this cycle
);

    localparam logic [2:0] TYPE_LOW    = 3'd0;
    localparam logic [2:0] TYPE_HIGH   = 3'd1;
    localparam logic [2:0] TYPE_PULSE  = 3'd2;
    localparam logic [2:0] TYPE_CLOCK  = 3'd3;
    localparam logic [2:0] TYPE_SERIAL = 3'd4;

    // ---- active (latched) configuration ----
    logic [2:0]          active_type;
    logic                active_idle_level;
    logic [TICK_W-1:0]   active_delay;
    logic [TICK_W-1:0]   active_param_a;
    logic [TICK_W-1:0]   active_param_b;
    logic [TICK_W-1:0]   active_cycles;
    logic                active_msb_first;
    logic [TICK_W-1:0]   active_bits;
    logic [SERIAL_W-1:0] active_data;    // original pattern, kept so re-RUNning without a
                                          // fresh apply restores it (shift_reg gets consumed)

    // ---- internal state ----
    logic [TICK_W-1:0]   delay_cnt;
    logic                delay_done;         // delay_cnt has reached active_delay
    logic [TICK_W-1:0]   period_cnt;         // CLOCK: position within current period
    logic [TICK_W-1:0]   pulse_cnt;          // PULSE: position within current width/repeat-period
    logic [TICK_W-1:0]   cycle_cnt;          // CLOCK periods completed | PULSE repeats completed
    logic [SERIAL_W-1:0] shift_reg;
    logic [TICK_W-1:0]   bit_cnt;

    assign delay_done = (delay_cnt >= active_delay);

    // how many repeats this type is supposed to do before finishing
    // (CLOCK: 0 = free-running / never finishes; PULSE: 0 or 1 both mean "once")
    logic [TICK_W-1:0] target_cycles;
    assign target_cycles = (active_type == TYPE_PULSE && active_cycles == 0) ? 32'd1 : active_cycles;
    logic clock_free_running;
    assign clock_free_running = (active_type == TYPE_CLOCK) && (active_cycles == 0);
    logic cycles_exhausted;
    assign cycles_exhausted = !clock_free_running && (cycle_cnt >= target_cycles);

    logic bits_exhausted;
    assign bits_exhausted = (bit_cnt >= active_bits);

    assign active = run && delay_done
                     && ((active_type == TYPE_SERIAL) ? !bits_exhausted : !cycles_exhausted);

    // ---- combinational: what pin_out should become this cycle ----
    // `run` gates everything up front (single place, not a case-then-override), and
    // every type is one flat ternary -- deliberately avoiding `unique case`, which this
    // toolchain's simulator (Icarus 13.0) only partially supports for this pattern.
    logic next_pin_out;
    always_comb begin
        if (!run) begin
            next_pin_out = active_idle_level;
        end else begin
            case (active_type)
                TYPE_LOW:  next_pin_out = 1'b0;
                TYPE_HIGH: next_pin_out = 1'b1;
                TYPE_PULSE:
                    next_pin_out = (!delay_done || cycles_exhausted) ? active_idle_level
                                   : (pulse_cnt < active_param_a) ? ~active_idle_level : active_idle_level;
                TYPE_CLOCK:
                    next_pin_out = (!delay_done || cycles_exhausted) ? active_idle_level
                                   : (period_cnt < active_param_b) ? ~active_idle_level : active_idle_level;
                TYPE_SERIAL:
                    next_pin_out = (!delay_done || bits_exhausted) ? active_idle_level
                                   : (active_msb_first ? shift_reg[SERIAL_W-1] : shift_reg[0]);
                default: next_pin_out = active_idle_level;
            endcase
        end
    end

    logic done_now;
    always_comb begin
        if (active_type == TYPE_SERIAL)
            done_now = run && delay_done && !bits_exhausted && (bit_cnt == active_bits - 1)
                       && shift_strobe;
        else
            done_now = run && delay_done && !cycles_exhausted && !clock_free_running
                       && (cycle_cnt == target_cycles - 1)
                       && ((active_type == TYPE_CLOCK && period_cnt == active_param_a - 1)
                           || (active_type == TYPE_PULSE
                               && ((target_cycles == 1 && pulse_cnt == active_param_a - 1)
                                   || (target_cycles > 1 && pulse_cnt == active_param_b - 1))));
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_type       <= TYPE_LOW;
            active_idle_level <= 1'b0;
            active_delay       <= '0;
            active_param_a     <= '0;
            active_param_b     <= '0;
            active_cycles      <= '0;
            active_msb_first   <= 1'b1;
            active_bits        <= '0;
            active_data        <= '0;

            delay_cnt  <= '0;
            period_cnt <= '0;
            pulse_cnt  <= '0;
            cycle_cnt  <= '0;
            shift_reg  <= '0;
            bit_cnt    <= '0;

            pin_out      <= 1'b0;
            rising_edge  <= 1'b0;
            falling_edge <= 1'b0;
            done         <= 1'b0;
        end else begin
            rising_edge  <= (next_pin_out && !pin_out);
            falling_edge <= (!next_pin_out && pin_out);
            pin_out      <= next_pin_out;
            done         <= done_now;

            if (apply) begin
                active_type       <= cfg_type;
                active_idle_level <= cfg_idle_level;
                active_delay       <= cfg_delay;
                active_param_a     <= cfg_param_a;
                active_param_b     <= cfg_param_b;
                active_cycles      <= cfg_cycles;
                active_msb_first   <= cfg_msb_first;
                active_bits        <= cfg_bits;
                active_data        <= cfg_data;

                delay_cnt  <= '0;
                period_cnt <= '0;
                pulse_cnt  <= '0;
                cycle_cnt  <= '0;
                bit_cnt    <= '0;
                shift_reg  <= cfg_data;
            end else if (!run) begin
                // not applying, not running: hold ready to replay the same configured
                // sequence the next time run asserts, with no fresh apply needed.
                delay_cnt  <= '0;
                period_cnt <= '0;
                pulse_cnt  <= '0;
                cycle_cnt  <= '0;
                bit_cnt    <= '0;
                shift_reg  <= active_data;
            end else if (!delay_done) begin
                delay_cnt <= delay_cnt + 1'b1;
            end else begin
                case (active_type)
                    TYPE_CLOCK: begin
                        if (!clock_free_running && cycles_exhausted) begin
                            // finished -- hold at idle, counters frozen until next apply/run edge
                        end else if (period_cnt == active_param_a - 1) begin
                            period_cnt <= '0;
                            cycle_cnt  <= cycle_cnt + 1'b1;
                        end else begin
                            period_cnt <= period_cnt + 1'b1;
                        end
                    end
                    TYPE_PULSE: begin
                        if (cycles_exhausted) begin
                            // finished
                        end else if (target_cycles == 1) begin
                            if (pulse_cnt == active_param_a - 1) begin
                                pulse_cnt <= pulse_cnt;  // one-shot: stay done, cycles_exhausted catches it next
                                cycle_cnt <= cycle_cnt + 1'b1;
                            end else begin
                                pulse_cnt <= pulse_cnt + 1'b1;
                            end
                        end else begin
                            if (pulse_cnt == active_param_b - 1) begin
                                pulse_cnt <= '0;
                                cycle_cnt <= cycle_cnt + 1'b1;
                            end else begin
                                pulse_cnt <= pulse_cnt + 1'b1;
                            end
                        end
                    end
                    TYPE_SERIAL: begin
                        if (!bits_exhausted && shift_strobe) begin
                            bit_cnt   <= bit_cnt + 1'b1;
                            shift_reg <= active_msb_first
                                         ? {shift_reg[SERIAL_W-2:0], 1'b0}
                                         : {1'b0, shift_reg[SERIAL_W-1:1]};
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
