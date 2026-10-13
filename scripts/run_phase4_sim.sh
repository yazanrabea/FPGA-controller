#!/usr/bin/env bash
# Pre-validates phase4_loopback_top.sv with Icarus Verilog before it ever
# touches Vivado (no Vivado/license in this environment -- see CLAUDE.md §4
# and docs/experiments/EXP-05 for what still needs real hardware). Does NOT
# synthesize, program a board, or take any measurement.
#
# Usage: scripts/run_phase4_sim.sh   (run from the repo root)
set -euo pipefail

IVERILOG=$(command -v iverilog || echo /opt/homebrew/bin/iverilog)
VVP=$(command -v vvp || echo /opt/homebrew/bin/vvp)

SRC=fpga/src
TB=fpga/tb
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Regenerating $SRC/gen/nemo_cfg_pkg.svh from config/phase4_loopback_test.yaml..."
(cd tools && python3 -m nemo_ctl.gen_svh)
echo

echo "=== phase4_loopback_top_tb ==="
"$IVERILOG" -g2012 -o "$WORK/phase4.vvp" \
    "$SRC/gen/nemo_cfg_pkg.svh" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/phase4_loopback_top.sv" "$TB/phase4_loopback_top_tb.sv"
"$VVP" "$WORK/phase4.vvp"
