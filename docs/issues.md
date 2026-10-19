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
