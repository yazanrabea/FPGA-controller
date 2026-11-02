#!/usr/bin/env bash
# Verification plan Step 2 (pad readback): readback_cell testbench.
# Icarus Verilog, or Vivado xsim if Icarus isn't installed (scripts/sim_lib.sh).
#
# Usage: scripts/run_readback_sim.sh   (run from the repo root; SIM=xsim to force xsim)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

echo "=== readback_cell_tb ==="
sim_run readback_cell_tb fpga/src/readback_cell.sv fpga/tb/readback_cell_tb.sv
