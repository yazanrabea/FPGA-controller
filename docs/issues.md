# Issues and fixes

Format: symptom, suspected cause, fix, confirmation.

## Switch bounce caused false faults in the clock checker
- Symptom: fault latch (LD3) set right after flipping `sw[4]`.
- Cause: asynchronous, bouncing switch input.
- Fix: 2-FF synchronizer on `sw[4]` plus ~20 ms settle window before checking.
- Confirmation: pair 0 runs at 1 MHz with LD3 off [measured on board].

## Fault latch too sensitive / compared against the wrong cycle
- Symptom: single-cycle mismatches latched a fault.
- Cause: the readback passes through a 2-FF input synchronizer, so it lags the driven value by 2 cycles.
- Fix: delay the expected value by 2 cycles; latch a fault only after 16 consecutive mismatches.
- Confirmation: pair 0 passes [measured on board]. Note: a self-check can lie; confirm with an independent instrument.

## Scope readings: low level or ringing
- Symptom: with 50 ohm scope input, 1.8 V reads ~0.7 V; with 1 Mohm input, ringing on edges.
- Cause: 50 ohm input loads the LVCMOS18 pin; 1 Mohm doesn't terminate the jumper-wire line.
- Fix / practice: use 1 Mohm for true levels and accept ringing on jumper wires; 1 MHz looks clean, 100 MHz looks rounded.
- Status: open, revisit with proper probing (ground spring, short leads) during scope/ILA verification.

## Testbenches passed in Icarus but failed to elaborate in Vivado xsim
- Symptom (2026-10-19, first run on the Windows lab PC): `link_ctrl_tb` failed with `VRFC 10-3818: variable 'resp_count' is driven by invalid combination of procedural drivers`; `phase4_loopback_top_tb` failed with `XSIM 43-4100: Module phase4_loopback_top_tb has a timescale but at least one module in design doesn't have timescale`. Both had passed under Icarus Verilog.
- Cause: Icarus is more lenient than the standard. (1) `fpga/tb/link_ctrl_tb.sv`'s mock uart_tx wrote `resp_count` in an `always_ff` while tasks also cleared it; IEEE 1800 allows only one driver for an `always_ff` variable. (2) The generated `fpga/src/gen/nemo_cfg_pkg.svh` had no `` `timescale `` while every other file does.
- Fix: plain `always` for that testbench-only mock; `tools/nemo_ctl/gen_svh.py` now emits `` `timescale 1ns / 1ps ``. Also made the sim scripts fall back to xsim (`scripts/sim_lib.sh`) so both simulators get used.
- Confirmation: all 8 testbenches pass in xsim 2022.1 through `scripts/run_phase{3_sims,4_sim,5_link_sim}.sh` [simulated]. Not yet re-checked under Icarus (not installed on the lab PC); the changes are standard SV that Icarus already accepted in equivalent form.
- Lesson: run new testbenches in xsim too, not only Icarus.

## Phase 4 top failed Vivado synthesis: generated package `.svh` never compiled
- Symptom (2026-10-19, first Vivado build of `phase4_loopback_top`): `ERROR: [Synth 8-36] 'nemo_cfg_pkg' is not declared [fpga/src/phase4_loopback_top.sv:99]` (and every other `nemo_cfg_pkg::` reference). Icarus and xsim had both passed, because the sim scripts list the file explicitly as a source.
- Cause: Vivado treats `*.svh` as an include-only header and never compiles it on its own. Forcing `file_type SystemVerilog` on it in `create_project.tcl` put it in `read_verilog`, but synthesis still failed the same way. The same files elaborate fine (`synth_design -rtl`) once the package file is named `.sv`.
- Fix: `tools/nemo_ctl/gen_svh.py` now writes `fpga/src/gen/nemo_cfg_pkg.sv` (renamed with `git mv`); `scripts/create_project.tcl` globs `fpga/src/gen/*.sv`; `run_phase4_sim.sh` and current docs updated. The generator keeps its name `gen_svh.py` so documented commands don't change.
- Confirmation: `create_project.tcl -tclargs phase4_loopback_top build` completes, no errors or critical warnings, timing met (WNS +3.702 ns, WHS +0.117 ns); `run_phase4_sim.sh` 21/21 [simulated]; pytest 101 passed, 1 skipped.
- Lesson: simulation passing does not mean Vivado synthesis will accept the same file set; build a new top in Vivado early.

## Dima's Q1 quirk is not "slice 0 loads zeros": sel[23:8] starts at the PREVIOUS load's slice 0
- Symptom (2026-10-22, `phase6_sipo_piso_tb`, Icarus 12): RUN 1 gave `sel = 0000a5` before the first `phirst`, as expected, but RUN 2 (same frame, reloaded) gave `sel = 1111a5`, i.e. slice 0 *did* show up.
- Cause: `sipo_wrapper.sv`'s reset branch does `sel[23:8] <= parallel_out[23:8]` and `sipo.sv`'s does `parallel_out <= '0`, both nonblocking on the same `negedge rst_n`. The right-hand side is read before either update lands, so `sel[23:8]` gets what the *previous* `cs` latched (0 only before the first load). Deterministic by the LRM's scheduling rules, not a race. The 2026-10-13 reading in `docs/controller_spec.md` Q1 ("loads zeros") only holds for the first load. Either way the slice 0 of the frame being loaded never reaches `sel`. Separately, an async reset that loads *data* (not a constant) does not map to a normal reset flip-flop in silicon; worth asking Dima how it synthesized.
- Fix: none to Dima's RTL (reference only). `sipo_piso.dima_sel_after()` takes a `prev_frame`; the testbench records `parallel_out[23:8]` before each RUN and expects that; Q1 in `docs/controller_spec.md` amended.
- Confirmation: `scripts/run_phase6_sim.sh` 69/69 [simulated, Icarus 12]. All 3 RUNs use the same frame, so "previous" vs "current" slice 0 is shown by RUN 1 (current frame's 0x1111 absent) + RUN 2 (previous load's 0x1111 present), not by a single RUN.

## Before the first APPLY, the controller holds the chip's active-low resets asserted
- Symptom (2026-10-22, `phase6_sipo_piso_tb`): after FPGA reset and before APPLY, `rst_sipo` = `rst_piso` = 0. They go to their configured idle level (1, inactive) only on APPLY.
- Cause: by design of `sig_cell.sv` (Phase 3): before any config is applied, `active_idle_level` and `pin_out` reset to 0 for every pin.
- Fix: none yet. Holding the chip in reset until configured is probably the *safe* state, but it disagrees with `docs/controller_spec.md` §3's "idle HIGH" and must be decided in Phase 8's power-up checklist (together with: are the resets active-low at the pad, Q6). The testbench now checks and documents the actual behaviour.
- Status: open, Phase 8.

## Icarus Verilog 12 (Windows winget package) rejects constructs Icarus 13 / xsim accept
- Symptom (2026-10-22, Yazan's laptop, `Icarus.Verilog` 12.2022.06.11 from winget): (1) `fpga/tb/uart_tb.sv:64: error: Cannot "return" from tasks.` so `run_phase5_link_sim.sh` doesn't elaborate; (2) Dima's `sipo_wrapper.sv:49: error: sel['sd23:'sd8] Part select is double-driving unresolved wire.` (`sel[7:0]` from an `assign`, `sel[23:8]` from an `always_ff`: disjoint bits, legal per IEEE 1800 §6.5 as we read it); (3) `vvp` assertion `child->wt_context==0 ...` (vthread.cc:3790) on a `fork ... join_any` + `disable` timeout.
- Cause: Icarus 12 is older than the Icarus 13 the macOS setup used, and doesn't support these.
- Fix: (1) not changed, Phase 5 code: run it under Icarus 13 or xsim. (2) `fpga/tb/sipo_wrapper_icarus_shim.sv`, Dima's module with only the `sel` driver split; `run_phase6_sim.sh` uses it only when `SIM=icarus`, xsim gets the original. (3) testbench uses a polling loop instead.
- Confirmation: `run_phase3_sims.sh` 28/16/9/16, `run_phase4_sim.sh` 21/21, `run_phase6_sim.sh` 69/69 under Icarus 12 [simulated]. Phase 5 and the Phase 6 run against Dima's *unmodified* `sipo_wrapper.sv` still need xsim (lab PC).

## Sim scripts picked a python3 without the project packages
- Symptom (2026-10-22, Yazan's laptop): `run_phase4_sim.sh` failed with `ModuleNotFoundError: No module named 'yaml'`.
- Cause: two Pythons installed; `python3` (3.13) has no `tools/requirements.txt` packages, `python` (3.10) does. `sim_python` chose `python3` because it merely ran.
- Fix: `scripts/sim_lib.sh` `sim_python` now picks `python3` only if it can `import yaml`, else `python`. Also: `sim_lib.sh` looks for Icarus in `C:/iverilog/bin` (Windows installer default), not only PATH and `/opt/homebrew/bin`.
- Confirmation: `run_phase4_sim.sh` 21/21 [simulated, Icarus 12]; `nemo_cfg_pkg.sv` regenerated byte-identical.

## Sequencer end-of-run re-apply wiped the capture results
- Symptom (2026-10-22, `phase7_seq_loopback_top_tb`, first run): LD6 (data_in matched 0xA5) came on, but reading `data_in`'s `capture_reg` after the sequence gave `0000`.
- Cause: my first `seq_engine.sv` re-applied step 0 to *every* cell when a sequence ended (done / fault / abort), cap cells included, and a `cap_cell` APPLY clears `capture_reg`. The result was gone before the PC could read it, which would break the Python program-verify loop (read after the run).
- Fix: the end-of-run re-apply goes to the sig cells only (pins back to step 0's idle levels); cap cells are re-applied only at reset (preload) and START. `cap_cell` still clears its edge counters when RUN drops (its Phase 3 design, unchanged, documented in USER_MANUAL §8.1).
- Confirmation: `seq_engine_tb` "cap1's result survives the end of the sequence" and `phase7_seq_loopback_top_tb` "data_in's result is still readable 1000 ticks after the sequence ended" pass; 31/31 and 27/27 [simulated, Icarus 12].

## Testbench monitors on posedge measured step timing +/-1 tick off
- Symptom (2026-10-22, `seq_engine_tb`, first run): 11 timing checks failed by exactly one tick, some early and some late, while every captured value was right.
- Cause: testbench only. The monitors were `always @(posedge clk)` blocks reading DUT registers that update on the same edge, a simulation race (which process runs first decides old vs new value).
- Fix: monitors sample at `negedge` (all registers settled); `cyc` = the tick a value appeared. Two other testbench mistakes fixed at the same time: a "never true" level that was briefly true while the pin changed type, and a clock-period count that couldn't be reached in the run.
- Confirmation: 31/31 [simulated]. Lesson: in a self-checking testbench, sample DUT outputs away from the clock edge that updates them.

## A pulled loopback jumper floats
- Symptom (design review, 2026-10-22, not observed on hardware): EXP-03's fault test pulls jumper J2-20 and expects the `en_in == 1` wait to time out. With no pull resistor, LA20_P would float and could read 1 by chance, so the test could pass or fail randomly.
- Fix: `fpga/constraints/phase7_seq_loopback_top.xdc` sets `PULLDOWN true` on LA16–LA20_P (this top only). The FPGA output driving through the jumper overrides the weak pull. Testbench models a pulled jumper as 0.
- Status: [simulated] only; confirm in EXP-03 Run 2.

## Phase 5 testbenches didn't compile under Icarus 12, and the original link_ctrl.sv misbehaves there
- Symptom (2026-10-22, Yazan's laptop, Icarus 12): all three Phase 5 testbenches failed to elaborate (`Cannot "return" from tasks`; `uart_tb` also `Assignment to an entire array ... not yet supported`). After rewriting those constructs: `uart_tb` 12/12, but `link_ctrl_tb` 16/22 and `phase5_link_top_tb` 4/7, with the **unchanged** `fpga/src/link_ctrl.sv`: config fields read back as `x` (`sig_cfg_param_a[0]=0xxxxxxxxx`, CTRL bits not decoded, test_clock never toggling).
- Cause: Icarus 12 limitations. The same RTL passed in xsim 2022.1 (lab PC, 2026-10-19) and Icarus 13 (macOS). The testbench constructs are confirmed unsupported. For `link_ctrl.sv` the suspect is its unpacked-array module ports (`output logic [31:0] sig_cfg_param_a[N_SIG]` driven from a generate loop), not yet proven.
- Fix: testbench-only, behaviour-preserving: `return` inside polling loops -> a loop-exit flag with the same tick timing and the same FAIL message; the 4-element array initializer -> four assignments. Phase 7 round 2 (R2.1) rewrites `link_ctrl.sv` with packed vector ports. The proof that Phase 5 still behaves the same is that the unchanged test checks pass (here and then in xsim), since there is no clean Icarus 12 baseline of the old RTL.
- Status (R2.0): `uart_tb` 12/12 [simulated, Icarus 12]; the rest is resolved by R2.1 (see the WORKLOG).
- Resolution (R2.1, same day): minimal repro confirmed the cause: Icarus 12 reads an unpacked-array *output port* driven from a generate loop as `x` (packed 2-D ports work). `link_ctrl.sv` now has packed `[N][W]` ports (outputs as `wire`, one driver per element) and sits on the new shared `fpga/src/link_frame.sv`. Result: `uart_tb` 12/12, `link_ctrl_tb` 22/22, `phase5_link_top_tb` 7/7 [simulated, Icarus 12], the same counts as xsim on 2026-10-19. Still to do: re-run in xsim on the lab PC.
- Intended behaviour change found by `link_ctrl_tb` (R2.1): a WRITE_REG now lands LEN+4 ticks after its checksum byte (input FIFO, checksum check, then one byte per tick on the register bus) instead of 2 ticks. The test fed the next frame 2 ticks after a write, faster than any UART can, so its three "check the live port right after a write" waits went from `tick(2)` to `tick(8)`; the checked values didn't change. Over real UART (one byte per ~8,680 ticks at 115200) the difference can't be seen, and `phase5_link_top_tb` (real UART timing) passes unchanged. `link_frame.sv` also gained a 16-byte input FIFO so back-to-back bytes are never dropped (sticky `rx_overflow` if it ever overflows); before the FIFO, the next frame's SOF was lost while a write was still on the bus.

## START sent during the new "reload step 0" state was silently dropped
- Symptom (2026-10-22, `seq_engine_tb` RUN E, while adding the Phase 7 round 2 prefetch): a START sent right after a sequence ended did nothing (`done=1 last=6 starts=0`, values left over from the previous run).
- Cause: my round-2 engine re-applies step 0 in a new `S_RELOAD` state that waits for the bank to fetch step 0 again (1 tick with a compile-time table, ~40 ticks with the link's RAM), and START was only accepted in `S_IDLE`.
- Fix: `seq_engine.sv` latches a START seen during `S_PRELOAD`/`S_RELOAD` (`start_q`) and runs it as soon as it reaches IDLE; ABORT cancels it. START while busy is still ignored, as before.
- Confirmation: `seq_engine_tb` RUN E and the new RUN I ("both STARTs ran") pass, 40/40 [simulated, Icarus 12]. The testbench's `wait_idle` also had to wait for real idle (not just `!busy`), since `S_RELOAD` isn't busy.

## link_frame lost the next frame's first byte while a write was still on the bus
- Symptom (2026-10-22, `link_ctrl_tb` after the R2.1 split): the echo test timed out with 0 response bytes; a trace showed the next frame's SOF arriving while the parser was still writing the previous frame's bytes (state DO_WRITE), so it was never seen.
- Cause: the new parser writes one byte per tick after the checksum (so a block RAM can sit on the bus), and couldn't take input meanwhile. `link_ctrl_tb` feeds bytes every 2 ticks. Real UART (one byte per ~8,680 ticks) never hits this.
- Fix: a 16-byte input FIFO in `link_frame.sv`. The parser takes bytes when it's ready, and overflow is flagged (sticky `rx_overflow`, v2 STATUS bit 7) instead of silent. Also fixed while there: a full FIFO popped on the same tick now accepts the incoming byte.
- Confirmation: `link_ctrl_tb` 22/22, `phase5_link_top_tb` 7/7, `phase7_link_top_tb` 21/21 (LD7 off) [simulated, Icarus 12].

## `seq_engine_tb` used signals before declaring them (xsim refused to compile it)
- Symptom (2026-10-22, first xsim run of Phase 7 on the lab PC): `run_phase7_sim.sh` stopped at `seq_engine_tb` with `VRFC 10-2938: 'fetch_step' is already implicitly declared` (also `fetch_ready`) and then `VRFC 10-3380: identifier 'fault_cyc' is used before its declaration`. Passed under Icarus 12.
- Cause: `fetch_step`/`fetch_ready`/`late` were declared after the DUT instance that connects them, and `fault_cyc` after the `clear_mon()` task that writes it. Icarus allows use-before-declaration; the standard and xsim don't.
- Fix: moved those declarations above their first use (`fpga/tb/seq_engine_tb.sv`). No check changed.
- Confirmation: all four Phase 7 testbenches pass in xsim 2022.1 with the same counts as Icarus: `seq_engine_tb` 40, `seq_bank_tb` 10, `phase7_seq_loopback_top_tb` 27, `phase7_link_top_tb` 21 [simulated]. The other three also compiled and elaborated with no error before the fix.

## `phase5_link_top` failed 100 MHz timing by 6.1 ns (divide by 24 in the read path)
- Symptom (2026-10-22, first Vivado synthesis + place + route of `phase5_link_top`, no bitstream since `rxd`/`txd` have no pins): `Timing constraints are not met`, WNS -6.148 ns, TNS -1129 ns, 1087 failing endpoints. Worst path `u_link_ctrl/u_frame/bus_raddr_reg` -> `u_link_ctrl/bus_rdata_reg`, 26 logic levels (15 CARRY4). Every simulation passed, because simulation has no timing.
- Cause: `fpga/src/link_ctrl.sv` `read_byte()` found the cap cell and byte with `(addr - CAP_BASE) / CAP_STRIDE` and `% CAP_STRIDE`, and `CAP_STRIDE` = 24 is not a power of 2, so synthesis built a divider. The divide was already in the original Phase 5 code (`5b045ef`); the Phase 7 R2.1 refactor kept it. `phase7_link_top` has the same expression but its stride is 16 (a shift), and it meets timing (WNS +0.334 ns).
- Fix: `read_byte()` now picks the cell with one constant range compare per cap cell (`for i < N_CAP`). Same register map, same values returned.
- Confirmation: `phase5_link_top` meets timing, WNS +0.238 ns, 0 failing endpoints [Vivado implementation report, not a measurement]; `run_phase5_link_sim.sh` in xsim `uart_tb` 12, `link_ctrl_tb` 22, `phase5_link_top_tb` 7 [simulated].
- Still tight: the worst path (9 levels) is now the 376-byte register-file read mux. If it fails after a change, register the address decode or make the register file a RAM.
- Lesson: run every new top through Vivado synthesis + routing (`report_timing_summary`) before calling it ready for the board, even when it can't make a bitstream yet.

## EXP-01: SERIAL checker (LD2) compared the wrong byte, never confirmed a good capture
- Symptom (2026-10-22, EXP-01 on the board): pair 2 (SERIAL 0xA5), `sw[4]` up for ~2 s: LD0/LD1 blinked the pattern (4 separate 1s), but LD2 (`serial_ok`) never came on. LD3 doesn't cover this pair.
- Cause: `fpga/src/phase4_loopback_top.sv` compared `capture_reg_serial[7:0] == TEST_SERIAL_DATA[7:0]`. The two sides hold a partial (8-of-16-bit) frame at opposite ends: `gen_svh.py` packs MSB-first send data MSB-justified (`16'hA500`), while `cap_cell`'s MSB-first capture lands at the bottom (`[7:0]`, documented in `cap_cell.sv`). So it compared 0xA5 with 0x00. It also *passed* with the jumper pulled (0x00 == 0x00). `phase4_loopback_top_tb` only checked the first bit: a full frame at the 10 Hz strobe is 80M ticks, so nothing simulated the compare.
- Fix: compare the BITS meaningful bits of each side, for either bit order (`SER_EXP` / `ser_got`). New `fpga/tb/phase4_serial_tb.sv`, run by `run_phase4_sim.sh` against a temp copy of the package with the strobe at 1 MHz: jumper in -> LD2 on, jumper pulled -> LD2 off. The old RTL fails both cases of it.
- Confirmation: `phase4_serial_tb` 2/2 and `phase4_loopback_top_tb` 21/21 [simulated, xsim]; rebuilt bitstream (WNS +4.001 ns), reprogrammed, pair 2 rerun: LD2 on [measured on board].
- Lesson: a checker on the board needs its own end-to-end test, time-scaled if needed. The board run found what the testbench couldn't reach.

## EXP-01: one LD3 (fault latch) transient on pair 4, cause not found (open)
- Symptom (2026-10-22): reading pair 4 (HIGH) with RUN on, LD3 was on; it had been off at the pair 3 reading just before. It cleared when `sw[4]` was toggled.
- Checked: the latch counts mismatches of the *selected* pair only (16 consecutive ticks = 160 ns); `sel` falls back to pair 0 for `sw[3:0]` >= 5, so passing through other switch values shouldn't set it. Retest on the fixed bitstream: `sw[2:0]`=100, RUN on, nothing touched for 30 s: off; then 100 -> 011 -> 100: still off.
- Suspected: a brief real dropout on a jumper (e.g. bumped while flipping the nearby switches). Not proven.
- Status: open. Watch LD3 in EXP-03 (same jumpers); if it comes back, wiggle-test the jumpers one by one with the pair selected.

## JTAG USER1 register overwritten by hw_server (EXP-05)
- Symptom (2026-10-22, `jtag_echo_top` on USER1, xsdb over J17): 12/500 scans read back all ones (15 MHz, no `jtag lock`), 14/500 at 5 MHz; the write side of those scans still landed. The stored value was 0 at the start of every new xsdb session. With the session held open unlocked, all 8 LEDs blinked (the design can only show one fixed byte).
- Cause (inferred from the symptoms, not from documentation): hw_server scans the BSCAN USER registers itself, for debug-core discovery (Vivado's debug hub uses USER1 by default), and writes into ours. Not signal integrity: lowering TCK to 5 MHz didn't help; `jtag lock` (exclusive access) gave 0/500.
- Fix: `jtag_echo_top` moved to **USER4** (IR `0x23`, `JTAG_CHAIN` parameter). The script keeps `jtag lock` anyway.
- Confirmation [measured on board]: USER4, no lock: 0/500 bad; value kept 60 s unlocked and across disconnect + reconnect; LEDs steady at 0xC1; `jtag_echo_test.tcl C1 2000` all pass.
- For J2: the real bridge must also reject scans without a valid header, so stray scans can't inject link bytes.

## phase7_link_jtag_top missed 100 MHz by 0.037 ns (sequencer COND_AFTER path)
- Symptom (2026-10-22, first Vivado build of `phase7_link_jtag_top`): `Timing constraints are not met`, sys clk WNS -0.037 ns, 2 failing endpoints (`u_core/u_engine/step_reg[0..1]/CE`). Path: `u_engine/apply_pulse_reg` -> `seq_bank`'s `hdr` mux (`apply_tick ? next_entry : cur_hdr`) -> `seq_engine` `COND_AFTER` test -> `step`, 14 levels with 4 CARRY4. The UART build `phase7_link_top` had passed the same path at +0.334 ns; the bridge's extra logic shifted placement enough to tip it over.
- Cause: `cond_met = (step_cnt == step_cond_arg - 1)` put a 32-bit subtract on the arg, which arrives late through the `hdr` mux.
- Fix (`fpga/src/seq_engine.sv`): a second counter register `step_cnt1`, always `step_cnt + 1`, set to 1 wherever `step_cnt` is set to 0. `COND_AFTER` is now `step_cnt1 == arg`: the same test, without the subtract.
- Confirmation: `seq_engine_tb` 40/40 (it checks COND_AFTER's tick-exact timing), `seq_bank_tb` 10, `phase7_seq_loopback_top_tb` 27, `phase7_link_top_tb` 21, `jtag_link_e2e_tb` 11 [simulated, xsim]; `phase7_link_jtag_top` rebuilt: timing met, sys clk WNS +0.427 ns [Vivado report].
- Note: EXP-03 (PASS on the board, 2026-10-22) was measured on the bitstream from before this change. **Rerun 2026-10-26 on the new bitstream: identical PASS** (EXP-03, "Rerun"), so this is closed.
- Side effect: `phase7_seq_loopback_top` rebuilt with the change still meets timing, but WNS went from +0.248 to **+0.100 ns**. Its critical path is the compile-time step-table mux by `step` (WORKLOG review, 2026-10-22), not COND_AFTER, so this is placement variation on an already tight path. Watch item: if it ever fails, register the current step's table entry (like `seq_bank` does).

## `cli link set-clock` printed low frequencies as 0.0000 MHz
- Symptom (2026-10-22, EXP-02 over JTAG): `--freq 1Hz` printed `requested 0.0000 MHz -> achieved 0.0000 MHz`. The tick counts printed were right (period 100,000,000).
- Cause: `tools/nemo_ctl/cli.py` always formatted `hz / 1e6` with 4 decimals.
- Fix: `_fmt_hz()` picks Hz / kHz / MHz. Test `test_fmt_hz_keeps_low_frequencies_readable`.
- Confirmation: pytest 213 passed, 1 skipped.

## EXP-06: overshoot / undershoot of 0.4-0.7 V on the jumper-wired outputs (open)
- Symptom (2026-10-26, CX3324A, 1 MΩ, DC coupling):
  - at 1 MHz, J3-0 (driving end) max 2.2 V / min -0.4 V, J3-16 (far end, an FPGA input)
    2.42 V / -0.7 V;
  - at 10 MHz, 2.1 / -0.4 V and ~2.3 / -0.64 V;
  - edges ~18 ns at 1 MHz.
- Suspected: reflections on the unterminated jumper wire (the far end rings more). The
  ground was the **shortest clip next to the measured pin** (reported 2026-10-26 after the
  run), so a long ground lead is ruled out, and most of the ringing is likely real. The
  probe/sensor model was not recorded.
- Why it matters: the chip's inputs will see this. -0.7 V below ground may be outside the
  chip's input rating (unknown: datasheet / Dima).
- Next: try `SLEW SLOW` / a lower `DRIVE` in the XDC (FPGA side only, no new wiring),
  rebuild and measure again; then a series resistor or shorter wires if needed. Optional:
  a spring-tip ground for a final check of the measurement.
- Update 2026-10-26: **DRIVE 4** (baseline DRIVE 12; slew was already SLOW) about halves it
  [measured on board, EXP-06 §6]: J3-0 1.97 / -0.25 V, J3-16 2.09 / -0.41 V, edges ~20 ns.
  **Partly mitigated**, not closed: -0.41 V remains at the far end, and the chip's input
  rating is unknown. Options after that: a series resistor at the driver, or shorter wires.
  Not decided: whether chip-facing outputs should use DRIVE 4.

## XsdbScanPort could freeze the JTAG link if xsdb printed a lot (latent, fixed)
- Found in review 2026-10-26, not seen on the board: `tools/nemo_ctl/jtag.py` started xsdb
  with `stdout=PIPE` and stopped reading it after the `READY` line. A burst of xsdb output
  (warnings, errors) would fill the pipe, freeze xsdb in its next print, and hang the link
  with no error.
- Reproduced with `tools/nemo_ctl/tests/_fake_xsdb_server.py`, a stand-in server that floods
  stdout after READY: without the fix the scan timed out (`TimeoutError`).
- Fix: a daemon thread keeps draining xsdb's output into `XsdbScanPort.output` (last 50
  lines). Those lines are included when the server closes the connection unexpectedly.
- Confirmation: `test_xsdb_port_survives_a_chatty_server` passes; pytest 235 passed,
  1 skipped; a real-board STATUS through the fixed class worked (2026-10-26).

## 2026-10-26: `run-mode --duration 20s` refused ("not a duration: '2e+07us'")
- Symptom: EXP-07 pass 3 diagnostic run, `run-mode --mode INFERENCE --duration 20s --jtag` ->
  `error: not a duration: '2e+07us'`; nothing sent to the board.
- Cause: `mode_seq.mode_steps` wrote the step length as `f"{duration_s * 1e6:g}us"`; `:g`
  switches to exponent form above 6 digits and `units.parse_duration_ns` doesn't parse it.
  The tests only used durations up to 2 ms.
- Fix: write whole nanoseconds (`f"{round(duration_s * 1e9)}ns"`); test with 20 s
  (2,000,000,000 ticks) added to `test_mode_seq.py`. Confirmed: the same command then ran
  (`STATUS: done`). [PC + board]
