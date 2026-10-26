#!/usr/bin/env bash
# Chip pipeline step C6: vchip_top (chip_top + Dima's SIPO/PISO as a virtual chip) end to
# end in simulation, the jumpers modelled as wires (fpga/tb/vchip_top_tb.sv). Regenerates
# chip_pkg / vchip_pkg + their XDCs and writes config/chip_sim_test.yaml's encoded table to
# a temp package. Dima's files are used unmodified; under Icarus 12 sipo_wrapper.sv needs
# the shim (fpga/tb/sipo_wrapper_icarus_shim.sv, as in run_phase6_sim.sh).
#
# Usage: scripts/run_vchip_sim.sh   (run from the repo root; SIM=xsim to force xsim)
set -euo pipefail
source "$(dirname "$0")/sim_lib.sh"

SRC=fpga/src
TB=fpga/tb
DIMA=fpga/reference/dima_blocks

echo "Regenerating chip_pkg / vchip_pkg + XDCs from config/nemo_config.yaml + config/exp08_vchip.yaml..."
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --chip && "$(sim_python)" -m nemo_ctl.gen_svh --vchip)
TBL="$WORK/chip_tb_pkg.sv"
(cd tools && "$(sim_python)" -m nemo_ctl.gen_svh --chip \
    --table-out "$(cd "$(dirname "$TBL")" && pwd)/$(basename "$TBL")")
echo

if [ "$SIM" = icarus ]; then
    SIPO_WRAPPER="$TB/sipo_wrapper_icarus_shim.sv"
    echo "NOTE: Icarus -> using $SIPO_WRAPPER instead of $DIMA/sipo_wrapper.sv"
else
    SIPO_WRAPPER="$DIMA/sipo_wrapper.sv"
fi

echo "=== vchip_top_tb (controller + virtual chip over jumpers: 136-bit frame in, 168 bits back) ==="
sim_run vchip_top_tb \
    "$SRC/gen/chip_pkg.sv" "$SRC/gen/vchip_pkg.sv" "$TBL" \
    "$SRC/link_frame.sv" "$SRC/sig_cell.sv" "$SRC/cap_cell.sv" \
    "$SRC/seq_engine.sv" "$SRC/seq_bank.sv" \
    "$SRC/jtag_link_bridge.sv" "$SRC/jtag_link_bscan.sv" "$SRC/chip_top.sv" \
    "$TB/tower_cell_stubs.sv" "$DIMA/piso.sv" "$SRC/virtual_chip.sv" "$SRC/vchip_top.sv" \
    "$TB/bscane2_sim_stub.sv" "$TB/vchip_top_tb.sv" \
    "$DIMA/sipo.sv" "$SIPO_WRAPPER"
