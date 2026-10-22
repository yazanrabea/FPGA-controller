#!/usr/bin/env bash
# JTAG link testbenches (docs/decisions.md: PC link = JTAG over J17), Icarus or
# Vivado xsim (scripts/sim_lib.sh). The BSCANE2 primitive itself isn't simulated:
# the TCK-domain logic sits in its own module so it can be tested without unisims.
#
# Usage: scripts/run_jtag_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

echo "=== jtag_echo_core_tb (J1: user DR echo) ==="
sim_run jtag_echo_core_tb "$SRC/jtag_echo_core.sv" "$TB/jtag_echo_core_tb.sv"

echo
echo "=== jtag_link_bridge_tb (J2: link bytes over USER scans, both directions) ==="
sim_run jtag_link_bridge_tb "$SRC/jtag_link_bridge.sv" "$TB/jtag_link_bridge_tb.sv"

# J3: both JTAG link tops end to end, real link frames through the bridge. Only the
# BSCANE2 primitive is replaced (fpga/tb/bscane2_sim_stub.sv, simulation only).
echo
echo "=== jtag_link_e2e_tb (J3: phase5/phase7 link tops over JTAG, end to end) ==="
sim_run jtag_link_e2e_tb \
    "$SRC/gen/phase7_link_pkg.sv" \
    "$SRC/uart_rx.sv" "$SRC/uart_tx.sv" "$SRC/link_frame.sv" "$SRC/link_ctrl.sv" \
    "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/seq_engine.sv" "$SRC/seq_bank.sv" \
    "$SRC/jtag_link_bridge.sv" "$SRC/jtag_link_bscan.sv" \
    "$SRC/phase5_link_top.sv" "$SRC/phase5_link_jtag_top.sv" \
    "$SRC/phase7_link_top.sv" "$SRC/phase7_link_jtag_top.sv" \
    "$TB/bscane2_sim_stub.sv" "$TB/jtag_link_e2e_tb.sv"
