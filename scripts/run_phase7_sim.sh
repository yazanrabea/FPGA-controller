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

echo "=== seq_bank_tb (round 2: step-table RAM + next-step bank) ==="
sim_run seq_bank_tb "$SRC/seq_bank.sv" "$TB/seq_bank_tb.sv"

# The top's real package runs for seconds (human-speed LEDs); simulate a
# time-scaled copy instead (same steps, x1e-4 ticks). It's written to the
# scratch dir, never to fpga/src/gen, so it can't end up in a bitstream.
echo
echo "Regenerating $SRC/gen/phase7_cfg_pkg.sv (hardware) and a x1e-4 copy for simulation..."
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --phase7)
SCALED="$WORK/phase7_cfg_pkg_sim.sv"
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --phase7 --time-scale 1e-4 \
    --out "$(cd "$(dirname "$SCALED")" && pwd)/$(basename "$SCALED")")

echo "=== phase7_seq_loopback_top_tb ==="
sim_run phase7_seq_loopback_top_tb \
    "$SCALED" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$SRC/seq_engine.sv" \
    "$SRC/phase7_seq_loopback_top.sv" "$TB/phase7_seq_loopback_top_tb.sv"

# Round 2: the same sequence loaded over the UART link. The layout package goes to
# fpga/src/gen (hardware); the encoded x1e-4 table is a simulation-only package in
# the scratch dir.
echo
echo "Regenerating $SRC/gen/phase7_link_pkg.sv and the x1e-4 table for the link testbench..."
TBL="$WORK/phase7_link_tb_pkg.sv"
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --phase7-link --time-scale 1e-4 \
    --table-out "$(cd "$(dirname "$TBL")" && pwd)/$(basename "$TBL")")

echo "=== phase7_link_top_tb (round 2: table over real UART, end to end) ==="
sim_run phase7_link_top_tb \
    "$SRC/gen/phase7_link_pkg.sv" "$TBL" "$SRC/uart_rx.sv" "$SRC/uart_tx.sv" \
    "$SRC/link_frame.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$SRC/seq_engine.sv" \
    "$SRC/seq_bank.sv" "$SRC/phase7_link_top.sv" "$TB/phase7_link_top_tb.sv"
