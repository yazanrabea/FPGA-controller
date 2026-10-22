#!/usr/bin/env bash
# Phase 7: seq_engine (step sequencer) testbenches. Icarus Verilog, or Vivado
# xsim if Icarus isn't installed (scripts/sim_lib.sh). Simulation only.
#
# Usage: scripts/run_phase7_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

echo "=== seq_engine_tb ==="
sim_run seq_engine_tb \
    "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$SRC/seq_engine.sv" "$TB/seq_engine_tb.sv"
