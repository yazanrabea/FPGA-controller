#!/usr/bin/env bash
# Pre-validates phase4_loopback_top.sv in simulation (Icarus Verilog, or Vivado
# xsim if Icarus isn't installed -- see scripts/sim_lib.sh and CLAUDE.md §4).
# docs/experiments/EXP-01 covers what still needs real hardware. Does NOT
# synthesize, program a board, or take any measurement.
#
# Usage: scripts/run_phase4_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

echo "Regenerating $SRC/gen/nemo_cfg_pkg.svh from config/phase4_loopback_test.yaml..."
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh)
echo

echo "=== phase4_loopback_top_tb ==="
sim_run phase4_loopback_top_tb \
    "$SRC/gen/nemo_cfg_pkg.svh" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/phase4_loopback_top.sv" "$TB/phase4_loopback_top_tb.sv"
