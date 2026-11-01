#!/usr/bin/env bash
# Verification plan 2026-11-01 Step 3: sample_cell (in-FPGA logic analyser) testbench.
# Icarus Verilog, or Vivado xsim if Icarus isn't installed (scripts/sim_lib.sh).
#
# Usage: scripts/run_sample_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

echo "=== sample_cell_tb ==="
sim_run sample_cell_tb fpga/src/sample_cell.sv fpga/tb/sample_cell_tb.sv
