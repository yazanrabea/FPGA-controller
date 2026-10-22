#!/usr/bin/env bash
# Phase 6.4: phase6_sipo_piso_top driving Dima's UNMODIFIED SIPO/PISO RTL
# (fpga/reference/dima_blocks/) with the Tower cells stubbed. Icarus Verilog,
# or Vivado xsim if Icarus isn't installed (scripts/sim_lib.sh). Simulation
# only: no XDC, no chip-pin map yet.
#
# Usage: scripts/run_phase6_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb
DIMA=fpga/reference/dima_blocks

echo "Regenerating $SRC/gen/phase6_cfg_pkg.sv from config/phase6_sipo_piso.yaml..."
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --phase6)
echo

# sipo.sv / sipo_wrapper.sv have no `timescale of their own: keep them after a
# file that has one (piso.sv), so they inherit 1ns/1ps instead of a mix.
# Icarus 12 can't elaborate Dima's sipo_wrapper.sv (sel driven by both an
# assign and an always_ff); use the one-change stand-in there, the original
# everywhere else. See fpga/tb/sipo_wrapper_icarus_shim.sv.
if [ "$SIM" = icarus ]; then
    SIPO_WRAPPER="$TB/sipo_wrapper_icarus_shim.sv"
    echo "NOTE: Icarus -> using $SIPO_WRAPPER instead of $DIMA/sipo_wrapper.sv"
else
    SIPO_WRAPPER="$DIMA/sipo_wrapper.sv"
fi

echo "=== phase6_sipo_piso_tb ==="
sim_run phase6_sipo_piso_tb \
    "$SRC/gen/phase6_cfg_pkg.sv" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/phase6_sipo_piso_top.sv" "$TB/tower_cell_stubs.sv" \
    "$DIMA/piso.sv" "$DIMA/sipo.sv" "$SIPO_WRAPPER" \
    "$TB/phase6_sipo_piso_tb.sv"
