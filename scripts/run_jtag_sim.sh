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

echo "=== jtag_echo_core_tb (J1: USER1 DR echo) ==="
sim_run jtag_echo_core_tb "$SRC/jtag_echo_core.sv" "$TB/jtag_echo_core_tb.sv"
