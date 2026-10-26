#!/usr/bin/env bash
# Chip pipeline step C4: chip_top end to end in simulation (Icarus or Vivado xsim,
# scripts/sim_lib.sh). Regenerates chip_pkg.sv / chip_top.xdc from the config's pin_map,
# and writes config/chip_sim_test.yaml's encoded table to a temp package (never into
# fpga/src/gen). The BSCANE2 primitive is replaced by fpga/tb/bscane2_sim_stub.sv.
#
# Usage: scripts/run_chip_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

echo "Regenerating $SRC/gen/chip_pkg.sv + fpga/constraints/chip_top.xdc from config/nemo_config.yaml..."
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --chip)
TBL="$WORK/chip_tb_pkg.sv"
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --chip \
    --table-out "$(cd "$(dirname "$TBL")" && pwd)/$(basename "$TBL")")
echo

echo "=== chip_top_tb (22 + 4 cells, table over JTAG, 136-bit SIPO load, 168-bit PISO read) ==="
sim_run chip_top_tb \
    "$SRC/gen/chip_pkg.sv" "$TBL" \
    "$SRC/link_frame.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/seq_engine.sv" "$SRC/seq_bank.sv" \
    "$SRC/jtag_link_bridge.sv" "$SRC/jtag_link_bscan.sv" "$SRC/chip_top.sv" \
    "$TB/bscane2_sim_stub.sv" "$TB/chip_top_tb.sv"
