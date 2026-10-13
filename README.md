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
scripts/           create_project.tcl
docs/              worklog, experiments, decisions, issues, measurements
config/            nemo_config.yaml — generic controller config (source of truth)
tools/nemo_ctl/    Python config/validation tool for the generic controller, see its README
```

Generic, user-configurable NEMO chip controller (replaces the per-signal bring-up designs
above once it's hardware-ready): see [`docs/controller_spec.md`](docs/controller_spec.md)
and [`tools/nemo_ctl/README.md`](tools/nemo_ctl/README.md). Phase 1 (config format +
Python core, no hardware) is done; run `python3 -m pytest` from the repo root.

## Build
Vivado 2022.1, from the repo root:
```
vivado -mode batch -source scripts/create_project.tcl -tclargs fmc_clock_loopback
```
Then open `build/fmc_clock_loopback/fmc_clock_loopback.xpr` in Vivado.
Before programming: the ZedBoard **J18 (VADJ) jumper must be on 1V8**.
