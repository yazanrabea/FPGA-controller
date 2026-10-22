#!/usr/bin/env bash
# Pre-validates phase4_loopback_top.sv in simulation (Icarus Verilog, or Vivado
# xsim if Icarus isn't installed -- see scripts/sim_lib.sh and CLAUDE.md §4).
# docs/experiments/EXP-01 covers what still needs real hardware. Does NOT
# synthesize, program a board, or take any measurement.
#
# Usage: scripts/run_phase4_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb

echo "Regenerating $SRC/gen/nemo_cfg_pkg.sv from config/phase4_loopback_test.yaml..."
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh)
echo

echo "=== phase4_loopback_top_tb ==="
sim_run phase4_loopback_top_tb \
    "$SRC/gen/nemo_cfg_pkg.sv" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/phase4_loopback_top.sv" "$TB/phase4_loopback_top_tb.sv"

# The SERIAL pair end to end (phase4_loopback_top_tb can't reach it: 80M ticks per frame
# at the real 10 Hz strobe). Same RTL, a temp copy of the package with the strobe at 1 MHz.
# It lives in $WORK only, so it can never end up in a bitstream.
echo
echo "=== phase4_serial_tb (SERIAL pair end to end, strobe x1e5 faster) ==="
FAST="$WORK/nemo_cfg_pkg_fast.sv"
sed -E -e 's/(SERIAL_STROBE_PERIOD = )[0-9]+;/\1100;/' -e 's/(SERIAL_STROBE_HIGH   = )[0-9]+;/\150;/' \
    "$SRC/gen/nemo_cfg_pkg.sv" > "$FAST"
grep -q "SERIAL_STROBE_PERIOD = 100;" "$FAST" && grep -q "SERIAL_STROBE_HIGH   = 50;" "$FAST" \
    || { echo "ERROR: couldn't speed up the serial strobe in $FAST (package format changed?)"; exit 1; }
sim_run phase4_serial_tb \
    "$FAST" "$SRC/run_ctrl.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/phase4_loopback_top.sv" "$TB/phase4_serial_tb.sv"
