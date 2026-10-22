# FPGA-controller

FPGA digital signals generation system for Y-Flash based ANN analysis
(Project 10768, ASIC² Lab, Technion, NEMO research project).

A ZedBoard (Zynq XC7Z020) with an HTG-FMC-SMA-LVDS daughter board generates the
clocks, non-overlapping phases and serial data that the Y-Flash in-memory-compute
test chip needs, and reads its results back.

- **Start here:** [`CLAUDE.md`](CLAUDE.md) (project context, verified facts, rules, team workflow)
- **Progress log:** [`docs/WORKLOG.md`](docs/WORKLOG.md)
- **Pin verification status:** [`docs/pin_verification.md`](docs/pin_verification.md)

## Layout
```
fpga/src/          Verilog / SystemVerilog sources
fpga/tb/           testbenches
fpga/constraints/  XDC, one per top design
scripts/           create_project.tcl, program_board.tcl, run_phase*_sim*.sh (simulations)
docs/              worklog, handoff, user manual, experiments, decisions, issues, measurements
config/            nemo_config.yaml (chip config, source of truth) + per-phase test configs
tools/nemo_ctl/    Python tool for the generic controller (config, wizard, generators, link,
                   SIPO/PISO frames, step sequences), see its README
```

Generic, user-configurable NEMO chip controller (replaces the per-signal bring-up designs
above once it's hardware-ready): see [`docs/controller_spec.md`](docs/controller_spec.md),
the lab manual [`docs/USER_MANUAL.md`](docs/USER_MANUAL.md) and the current state in
[`docs/HANDOFF.md`](docs/HANDOFF.md). Phases 0-7 (round 1) are built and **simulated**;
none of the generic-controller designs has been run on the board yet (EXP-01/02/03 in
`docs/experiments/`). Tests: `python -m pytest tools/nemo_ctl/tests` from the repo root;
simulations: `scripts/run_phase3_sims.sh` ... `scripts/run_phase7_sim.sh` (Icarus Verilog or
Vivado xsim, Git Bash on Windows).

## Build
Vivado 2022.1, from the repo root:
```
vivado -mode batch -source scripts/create_project.tcl -tclargs fmc_clock_loopback
```
Then open `build/fmc_clock_loopback/fmc_clock_loopback.xpr` in Vivado.
Before programming: the ZedBoard **J18 (VADJ) jumper must be on 1V8**.
