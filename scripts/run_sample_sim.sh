#!/usr/bin/env bash
# Verification plan 2026-11-01 Step 3: sample_cell (in-FPGA logic analyser) testbench.
# Icarus Verilog, or Vivado xsim if Icarus isn't installed (scripts/sim_lib.sh).
#
# Usage: scripts/run_sample_sim.sh   (run from the repo root)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

echo "=== sample_cell_tb ==="
sim_run sample_cell_tb fpga/src/sample_cell.sv fpga/tb/sample_cell_tb.sv

# The sampler inside phase7_link_top (SAMPLER = 1, the core of sample_loopback_top),
# over the UART link, with config/phase7_seq_loopback.yaml's table at x1e-4 (as
# run_phase7_sim.sh: the layout package to fpga/src/gen, the table to the scratch dir).
echo
echo "Regenerating fpga/src/gen/phase7_link_pkg.sv and the x1e-4 table for the testbench..."
TBL="$WORK/phase7_link_tb_pkg.sv"
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --phase7-link --time-scale 1e-4 \
    --table-out "$(cd "$(dirname "$TBL")" && pwd)/$(basename "$TBL")")

SRC=fpga/src
echo "=== sample_loopback_top_tb (phase7_link_top with SAMPLER = 1, end to end) ==="
DUMP_A="$WORK/record_a.txt"; DUMP_B="$WORK/record_b.txt"
SIM_PLUSARGS="+dump_a=$(_native "$DUMP_A") +dump_b=$(_native "$DUMP_B")" \
sim_run sample_loopback_top_tb \
    "$SRC/gen/phase7_link_pkg.sv" "$TBL" "$SRC/uart_rx.sv" "$SRC/uart_tx.sv" \
    "$SRC/link_frame.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" "$SRC/seq_engine.sv" \
    "$SRC/seq_bank.sv" "$SRC/sample_cell.sv" "$SRC/phase7_link_top.sv" fpga/tb/sample_loopback_top_tb.sv

# The two records the testbench wrote, checked on the PC side (samples.py / seqwaves.py)
# against config/phase7_seq_loopback.yaml at the same x1e-4: record A (jumpers in) must
# pass on every pin, record B (clk_in pulled) must fail on clk_in only.
echo
echo "=== the RTL's records through tools/nemo_ctl/seqwaves.py ==="
(cd tools && PYTHONPATH=. "$(sim_python)" ../scripts/check_sample_dump.py "$DUMP_A" "$DUMP_B")
