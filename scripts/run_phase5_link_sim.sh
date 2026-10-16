#!/usr/bin/env bash
# Pre-validates the Phase 5 runtime link (uart_tx/uart_rx, link_ctrl, and
# phase5_link_top) with Icarus Verilog before any of it touches Vivado (no
# Vivado/license in this environment -- see CLAUDE.md §4 and
# docs/experiments/EXP-02 for what still needs real hardware). Does NOT
# synthesize, program a board, or take any measurement.
#
# Usage: scripts/run_phase5_link_sim.sh   (run from the repo root)
set -euo pipefail

IVERILOG=$(command -v iverilog || echo /opt/homebrew/bin/iverilog)
VVP=$(command -v vvp || echo /opt/homebrew/bin/vvp)

SRC=fpga/src
TB=fpga/tb
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "=== uart_tb (uart_tx + uart_rx loopback) ==="
"$IVERILOG" -g2012 -o "$WORK/uart.vvp" "$SRC/uart_tx.sv" "$SRC/uart_rx.sv" "$TB/uart_tb.sv"
"$VVP" "$WORK/uart.vvp"
echo

echo "=== link_ctrl_tb (frame parser + register file + command dispatch) ==="
"$IVERILOG" -g2012 -o "$WORK/link_ctrl.vvp" \
    "$SRC/link_ctrl.sv" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$TB/link_ctrl_tb.sv"
"$VVP" "$WORK/link_ctrl.vvp"
echo

echo "=== phase5_link_top_tb (real UART bit timing, end to end, exit criterion) ==="
"$IVERILOG" -g2012 -o "$WORK/phase5.vvp" \
    "$SRC/uart_rx.sv" "$SRC/uart_tx.sv" "$SRC/link_ctrl.sv" "$SRC/run_ctrl.sv" \
    "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$SRC/phase5_link_top.sv" "$TB/phase5_link_top_tb.sv"
"$VVP" "$WORK/phase5.vvp"
