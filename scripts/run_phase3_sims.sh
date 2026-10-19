#!/usr/bin/env bash
# Runs every Phase 3 self-checking testbench (sig_cell, cap_cell, run_ctrl,
# plus the small integration check) in simulation (Icarus Verilog, or Vivado
# xsim if Icarus isn't installed -- see scripts/sim_lib.sh), and the yosys xc7
# utilization estimate if yosys is installed. See CLAUDE.md §4 for why these
# tools are used locally alongside Vivado, not instead of it.
#
# Usage: scripts/run_phase3_sims.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

run_tb() {
    local name=$1; shift
    echo "=== $name ==="
    sim_run "$name" "$@"
    echo
}

run_tb sig_cell_tb      "$SRC/sig_cell.sv"                                   "$TB/sig_cell_tb.sv"
run_tb cap_cell_tb      "$SRC/cap_cell.sv"                                   "$TB/cap_cell_tb.sv"
run_tb run_ctrl_tb      "$SRC/run_ctrl.sv"                                   "$TB/run_ctrl_tb.sv"
run_tb integration_tb   "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$TB/integration_tb.sv"

echo "=== yosys xc7 utilization estimate ==="
YOSYS=$(command -v yosys || { [ -x /opt/homebrew/bin/yosys ] && echo /opt/homebrew/bin/yosys; } || true)
if [ -z "$YOSYS" ]; then
    echo "yosys not installed -- skipped (use Vivado's report_utilization instead)"
else
    "$YOSYS" -p "
read_verilog -sv $SRC/sig_cell.sv $SRC/cap_cell.sv $SRC/run_ctrl.sv $TB/utilization_estimate_top.sv
synth_xilinx -family xc7 -top utilization_estimate_top
stat
" 2>&1 | grep -E "FDCE|FDPE|LUT[2-6]|CARRY4|Estimated number of LCs" | tail -8
fi
