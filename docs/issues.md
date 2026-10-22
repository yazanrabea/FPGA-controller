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
