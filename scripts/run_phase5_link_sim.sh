#!/usr/bin/env bash
# Pre-validates the Phase 5 runtime link (uart_tx/uart_rx, link_ctrl, and
# phase5_link_top) in simulation (Icarus Verilog, or Vivado xsim if Icarus
# isn't installed -- see scripts/sim_lib.sh and CLAUDE.md §4).
# docs/experiments/EXP-02 covers what still needs real hardware. Does NOT
# synthesize, program a board, or take any measurement.
#
# Usage: scripts/run_phase5_link_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

echo "=== uart_tb (uart_tx + uart_rx loopback) ==="
sim_run uart_tb "$SRC/uart_tx.sv" "$SRC/uart_rx.sv" "$TB/uart_tb.sv"
echo

echo "=== link_ctrl_tb (frame parser + register file + command dispatch) ==="
sim_run link_ctrl_tb \
    "$SRC/link_ctrl.sv" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$TB/link_ctrl_tb.sv"
echo

echo "=== phase5_link_top_tb (real UART bit timing, end to end, exit criterion) ==="
sim_run phase5_link_top_tb \
    "$SRC/uart_rx.sv" "$SRC/uart_tx.sv" "$SRC/link_ctrl.sv" "$SRC/run_ctrl.sv" \
    "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$SRC/phase5_link_top.sv" "$TB/phase5_link_top_tb.sv"
