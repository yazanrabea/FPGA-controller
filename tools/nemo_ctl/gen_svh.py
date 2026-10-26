#!/usr/bin/env python3
"""Generate fpga/src/gen/nemo_cfg_pkg.sv from a compile-time test config.

Phase 4 of generic_controller_prompt.md ("Top level with compile-time
config, no link yet"): the generated package holds one group of localparams
per test pair -- sig_cell type + idle level + delay/param_a/param_b/cycles
(all pre-quantized to ticks via units.py, exactly like the rest of this
tool), plus which LA loopback pair it's wired to and which cap_cell capture
mode reads it back.

Default input is config/phase4_loopback_test.yaml (the bring-up test config),
NOT config/nemo_config.yaml (the real chip config, whose pin_map is still all
null -- there is no chip-pin -> FMC assignment yet to generate a real top
level from).

Re-run after editing the YAML (needs -m: this module reuses units.py via a relative
import, unlike gen_pin_db.py, so it can't run as a bare script path):
    cd tools && python3 -m nemo_ctl.gen_svh

Phase 6 (--phase6): config/phase6_sipo_piso.yaml -> fpga/src/gen/phase6_cfg_pkg.sv, the
SIPO_LOAD / PISO_READ profiles for phase6_sipo_piso_top.sv. Parsed and timing-checked by
sipo_piso.load_phase6_config; nothing is written if a check fails.
    cd tools && python3 -m nemo_ctl.gen_svh --phase6

Phase 7 (--phase7): config/phase7_seq_loopback.yaml -> fpga/src/gen/phase7_cfg_pkg.sv, the
step table for phase7_seq_loopback_top.sv (validated by sequence.compile_steps). A
simulation copy at another time scale goes elsewhere:
    cd tools && python3 -m nemo_ctl.gen_svh --phase7 --time-scale 1e-4 --out <file>

Phase 7 round 2 (--phase7-link): fpga/src/gen/phase7_link_pkg.sv, the step-entry byte
layout and link v2 register map for phase7_link_top.sv (sequence.entry_layout; no table
in it: the table arrives over the link). --table-out <file.sv> also writes the sequence's
encoded table as a small package (phase7_link_tb_pkg) for the testbench, at --time-scale.
    cd tools && python3 -m nemo_ctl.gen_svh --phase7-link [--table-out <file.sv> --time-scale 1e-4]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

from .sipo_piso import (PISO_BITS, SIPO_BITS, FrameError, dima_sel_after,
                        encode_piso_frame, load_phase6_config)
from .sequence import MAX_STEPS as SEQ_MAX_STEPS
from .link import (V2_CAP_BASE, V2_CAP_DATA, V2_LAST_STEP, V2_N_STEPS, V2_STATUS, V2_STEP,
                   V2_TABLE_BASE, v2_cap_bytes, v2_cap_stride)
from .sequence import (ENTRY_BYTES, PHASE7_LOOPBACK, SequenceError, encode_step, entry_layout,
                       load_sequence)
from .units import UnitsError, quantize_clock, quantize_duration

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG_PATH = REPO_ROOT / "config" / "phase4_loopback_test.yaml"
OUT_PATH = REPO_ROOT / "fpga" / "src" / "gen" / "nemo_cfg_pkg.sv"
PHASE6_CONFIG_PATH = REPO_ROOT / "config" / "phase6_sipo_piso.yaml"
PHASE6_OUT_PATH = REPO_ROOT / "fpga" / "src" / "gen" / "phase6_cfg_pkg.sv"
PHASE7_CONFIG_PATH = REPO_ROOT / "config" / "phase7_seq_loopback.yaml"
PHASE7_OUT_PATH = REPO_ROOT / "fpga" / "src" / "gen" / "phase7_cfg_pkg.sv"
PHASE7_LINK_OUT_PATH = REPO_ROOT / "fpga" / "src" / "gen" / "phase7_link_pkg.sv"
CHIP_CONFIG_PATH = REPO_ROOT / "config" / "nemo_config.yaml"
CHIP_PKG_OUT_PATH = REPO_ROOT / "fpga" / "src" / "gen" / "chip_pkg.sv"
CHIP_XDC_OUT_PATH = REPO_ROOT / "fpga" / "constraints" / "chip_top.xdc"
VCHIP_CONFIG_PATH = REPO_ROOT / "config" / "exp08_vchip.yaml"
VCHIP_PKG_OUT_PATH = REPO_ROOT / "fpga" / "src" / "gen" / "vchip_pkg.sv"
VCHIP_XDC_OUT_PATH = REPO_ROOT / "fpga" / "constraints" / "vchip_top.xdc"
CHIP_SIM_SEQ_PATH = REPO_ROOT / "config" / "chip_sim_test.yaml"

TICK_W = 32  # generous default for a 5-cell bring-up design; see sig_cell.sv's own default
DATA_FIELD_W = 16  # width of the generated *_DATA localparam (must match phase4_loopback_top.sv's SERIAL_W)

# Must match sig_cell.sv's TYPE_* localparams exactly.
SIG_TYPE = {"LOW": 0, "HIGH": 1, "PULSE": 2, "CLOCK": 3, "SERIAL": 4}
# Must match cap_cell.sv's MODE_* localparams exactly.
CAP_MODE = {"LEVEL": 0, "EDGE_COUNT": 1, "PERIOD": 2, "SERIAL": 3}


class GenError(ValueError):
    pass


def _quantize_pair(p: dict) -> dict:
    t = p["type"]
    idle_level = 0  # every test pair in this bring-up config idles low
    delay_ticks = quantize_duration(p.get("delay", 0)).ticks
    param_a = 0
    param_b = 0
    cycles = 0
    msb_first = 1
    data = 0
    bits = 0

    if t == "CLOCK":
        q = quantize_clock(p["freq"], p.get("duty", "50%"))
        param_a, param_b = q.period_ticks, q.high_ticks
        cycles = 0  # free-running
    elif t == "PULSE":
        param_a = quantize_duration(p["width"]).ticks
        repeat = int(p.get("repeat", 1))
        cycles = repeat
        if repeat > 1:
            param_b = quantize_duration(p["period"]).ticks
        if p.get("polarity", "active_high") == "active_low":
            idle_level = 1
    elif t == "SERIAL":
        bits = int(p["bits"])
        if bits > DATA_FIELD_W:
            raise GenError(f"{p['name']}: {bits} bits won't fit the generator's "
                            f"{DATA_FIELD_W}-bit DATA field")
        msb_first = 1 if p.get("msb_first", True) else 0
        raw = int(p["data"], 0) if isinstance(p["data"], str) else int(p["data"])
        # sig_cell.sv's header comment: cfg_data must already be packed MSB-justified
        # (for msb_first) or LSB-justified (for !msb_first) within the SERIAL_W-wide
        # register -- msb_first shifts left from the top bit, so a right-justified
        # value (raw's natural form) would present (DATA_FIELD_W - bits) padding
        # zero-bits first instead of the real data. !msb_first shifts right from the
        # bottom bit, so raw's natural right-justified form is already correct there.
        data = (raw << (DATA_FIELD_W - bits)) if msb_first else raw
    elif t in ("LOW", "HIGH"):
        pass
    else:
        raise GenError(f"{p['name']}: unknown type {t!r}")

    return dict(
        type=SIG_TYPE[t], idle_level=idle_level, delay=delay_ticks,
        param_a=param_a, param_b=param_b, cycles=cycles,
        msb_first=msb_first, data=data, bits=bits,
    )


def generate(config_path: Path | None = None) -> str:
    config_path = config_path or DEFAULT_CONFIG_PATH
    with open(config_path) as f:
        doc = yaml.safe_load(f)

    pairs = doc["pairs"]
    strobe_hz = doc["serial_strobe"]["freq"]
    strobe_q = quantize_clock(strobe_hz, "50%")

    lines = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py -- do not edit by hand.",
        # as_posix(): same text on Windows and macOS, so regenerating never makes a spurious diff
        f"// Source: {config_path.relative_to(REPO_ROOT).as_posix()}",
        "// Regenerate with: cd tools && python3 -m nemo_ctl.gen_svh",
        "`ifndef NEMO_CFG_PKG_SVH",
        "`define NEMO_CFG_PKG_SVH",
        "",
        # Every other unit in the design has a timescale; Vivado xsim refuses to elaborate
        # a mix (XSIM 43-4100), Icarus doesn't care. Same value as the rest of fpga/src.
        "`timescale 1ns / 1ps",
        "",
        "package nemo_cfg_pkg;",
        f"    localparam int TICK_W = {TICK_W};",
        "",
        "    // internal helper clock for test_serial's shift/capture strobe --"
        f" requested {strobe_hz}, achieved {strobe_q.achieved_hz:.4f} Hz"
        f" ({strobe_q.error_pct:+.2f}%)",
        f"    localparam logic [TICK_W-1:0] SERIAL_STROBE_PERIOD = {strobe_q.period_ticks};",
        f"    localparam logic [TICK_W-1:0] SERIAL_STROBE_HIGH   = {strobe_q.high_ticks};",
        "",
    ]

    for idx, p in enumerate(pairs):
        name = p["name"].upper()
        q = _quantize_pair(p)
        cap_mode = CAP_MODE[p["capture_mode"]]
        lines += [
            f"    // {p['name']}: type={p['type']}, LA pair {p['la_pair']}",
            f"    localparam int {name}_LA_PAIR = {p['la_pair']};",
            f"    localparam logic [2:0] {name}_TYPE = 3'd{q['type']};",
            f"    localparam logic {name}_IDLE = 1'b{q['idle_level']};",
            f"    localparam logic [TICK_W-1:0] {name}_DELAY = {q['delay']};",
            f"    localparam logic [TICK_W-1:0] {name}_PARAM_A = {q['param_a']};",
            f"    localparam logic [TICK_W-1:0] {name}_PARAM_B = {q['param_b']};",
            f"    localparam logic [TICK_W-1:0] {name}_CYCLES = {q['cycles']};",
            f"    localparam logic {name}_MSB_FIRST = 1'b{q['msb_first']};",
            f"    localparam logic [15:0] {name}_DATA = 16'h{q['data']:04x};",
            f"    localparam logic [TICK_W-1:0] {name}_BITS = {q['bits']};",
            f"    localparam logic [1:0] {name}_CAP_MODE = 2'd{cap_mode};",
            "",
        ]

    lines += ["endpackage", "", "`endif // NEMO_CFG_PKG_SVH", ""]
    return "\n".join(lines)


def _phase6_sig_lines(name: str, typ: str, idle: int, delay: int, param_a: int = 0,
                      param_b: int = 0, cycles: int = 0, bits: int = 0) -> list[str]:
    """One sig_cell's localparams, same field set as a Phase 4 pair."""
    n = name.upper()
    return [
        f"    // {name}: {typ}",
        f"    localparam logic [2:0] {n}_TYPE = 3'd{SIG_TYPE[typ]};",
        f"    localparam logic {n}_IDLE = 1'b{idle};",
        f"    localparam logic [TICK_W-1:0] {n}_DELAY = {delay};",
        f"    localparam logic [TICK_W-1:0] {n}_PARAM_A = {param_a};",
        f"    localparam logic [TICK_W-1:0] {n}_PARAM_B = {param_b};",
        f"    localparam logic [TICK_W-1:0] {n}_CYCLES = {cycles};",
        f"    localparam logic [TICK_W-1:0] {n}_BITS = {bits};",
        "",
    ]


def _idle(setting: dict) -> int:
    """Level while stopped / between pulses: an active-low PULSE and a HIGH pin idle
    high (so rst_piso stays inactive even while stopped), everything else low."""
    if setting["type"] == "HIGH":
        return 1
    return int(setting["type"] == "PULSE" and setting.get("polarity") == "active_low")


def generate_phase6(config_path: Path | None = None) -> tuple[str, tuple[str, ...]]:
    """(package text, warnings). Raises FrameError/UnitsError on a config that fails
    sipo_piso's checks, so a bad profile never reaches the RTL."""
    config_path = Path(config_path or PHASE6_CONFIG_PATH).resolve()
    c = load_phase6_config(config_path)
    s, p, sp, pp = c.sipo, c.piso, c.sipo_pins, c.piso_pins
    sipo_edge = "1'b1" if c.sipo_data_edge == "falling" else "1'b0"
    piso_edge = "1'b1" if c.piso_capture_edge == "falling" else "1'b0"

    lines = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --phase6 -- do not edit by hand.",
        f"// Source: {config_path.relative_to(REPO_ROOT).as_posix()}",
        "// Regenerate with: cd tools && python3 -m nemo_ctl.gen_svh --phase6",
        "// Timing checked by sipo_piso.check_sipo_load / check_piso_read before writing.",
        "`ifndef PHASE6_CFG_PKG_SV",
        "`define PHASE6_CFG_PKG_SV",
        "",
        "`timescale 1ns / 1ps",
        "",
        "package phase6_cfg_pkg;",
        f"    localparam int TICK_W = {TICK_W};",
        f"    localparam int SIPO_BITS = {SIPO_BITS};",
        f"    localparam int PISO_BITS = {PISO_BITS};",
        "",
        "    // ---- SIPO_LOAD ----",
    ]
    lines += _phase6_sig_lines("rst_sipo", "PULSE", _idle(sp["rst_sipo"]), s.rst_delay,
                               param_a=s.rst_width, cycles=1)
    lines += _phase6_sig_lines("clk_sipo", "CLOCK", 0, s.clk_delay, param_a=s.period,
                               param_b=s.high, cycles=s.cycles)
    lines += _phase6_sig_lines("sipo_in", "SERIAL", 0, s.data_delay, bits=SIPO_BITS)
    lines += [
        "    // bits == SIPO_BITS, so MSB-justified is the frame itself (bit 135 goes first)",
        "    localparam logic SIPO_IN_MSB_FIRST = 1'b1;",
        f"    localparam logic [SIPO_BITS-1:0] SIPO_IN_DATA = "
        f"{SIPO_BITS}'h{c.sipo_frame:0{SIPO_BITS // 4}x};",
        f"    // shift_strobe = clk_sipo {c.sipo_data_edge}_edge (UNCONFIRMED)",
        f"    localparam logic SIPO_IN_SHIFT_ON_FALLING = {sipo_edge};",
        "",
    ]
    lines += _phase6_sig_lines("cs", "PULSE", _idle(sp["cs"]), s.cs_delay,
                               param_a=s.cs_width, cycles=1)
    lines += ["    // ---- PISO_READ ----"]
    lines += _phase6_sig_lines("rst_piso", pp["rst_piso"]["type"], _idle(pp["rst_piso"]), 0)
    lines += _phase6_sig_lines("clk_piso", "CLOCK", 0, p.clk_delay, param_a=p.period,
                               param_b=p.high, cycles=p.cycles)
    lines += _phase6_sig_lines("shift", "PULSE", _idle(pp["shift"]), p.shift_delay,
                               param_a=p.shift_width, cycles=1)
    lines += [
        "    // piso_out: cap_cell SERIAL",
        f"    localparam logic [1:0] PISO_OUT_CAP_MODE = 2'd{CAP_MODE['SERIAL']};",
        "    localparam logic PISO_OUT_MSB_FIRST = 1'b1;",
        f"    localparam logic [TICK_W-1:0] PISO_OUT_BITS = {PISO_BITS};",
        f"    // capture_strobe = clk_piso {c.piso_capture_edge}_edge (UNCONFIRMED)",
        f"    localparam logic PISO_OUT_CAPTURE_ON_FALLING = {piso_edge};",
        "",
        "    // ---- Phase 6.4 testbench vectors ----",
        "    // sipo_wrapper sel[23:0] after rst_sipo + load + cs + n phirst edges, Dima's RTL",
        "    // as written, for a FIRST load. n=0: sel[23:8] = the previous load's slice 0",
        "    // (0 here, none before), never this frame's (Q1); n>=8 undefined (Q2).",
    ]
    for n in range(8):
        lines.append(f"    localparam logic [23:0] SIPO_TB_SEL_AFTER_{n} = "
                     f"24'h{dima_sel_after(c.sipo_frame, n):06x};")
    lines += ["", "    // Values the testbench drives into the piso2 stages (PISO0 first)."]
    for k, st in enumerate(c.tb_piso_stages):
        lines += [
            f"    localparam logic [13:0] PISO_TB_STAGE{k}_OUT1     = 14'h{st.out1:04x};",
            f"    localparam logic [6:0]  PISO_TB_STAGE{k}_TDC_OUT1 = 7'h{st.tdc_out1:02x};",
            f"    localparam logic [13:0] PISO_TB_STAGE{k}_OUT0     = 14'h{st.out0:04x};",
            f"    localparam logic [6:0]  PISO_TB_STAGE{k}_TDC_OUT0 = 7'h{st.tdc_out0:02x};",
        ]
    frame = encode_piso_frame(c.tb_piso_stages)
    lines += [
        "    // ...and the 168-bit frame cap_cell must capture from them",
        f"    localparam logic [PISO_BITS-1:0] PISO_TB_FRAME = "
        f"{PISO_BITS}'h{frame:0{PISO_BITS // 4}x};",
        "endpackage",
        "",
        "`endif // PHASE6_CFG_PKG_SV",
        "",
    ]
    return "\n".join(lines), c.warnings


def _packed(values: list[int], w: int) -> str:
    """Step-indexed values -> one packed literal, step k at bits [k*w +: w]."""
    total = 0
    for k, v in enumerate(values):
        if not 0 <= v < (1 << w):
            raise GenError(f"value {v} doesn't fit {w} bits")
        total |= v << (k * w)
    return f"{len(values) * w}'h{total:0{(len(values) * w + 3) // 4}x}"


def generate_phase7(config_path: Path | None = None, scale: float = 1.0) -> tuple[str, tuple[str, ...]]:
    """config/phase7_seq_loopback.yaml -> phase7_cfg_pkg for phase7_seq_loopback_top.
    Every per-step field is a packed vector over MAX_STEPS steps (step k at [k*W +: W]);
    steps past N_STEPS repeat the last one and are never reached. `scale` != 1 makes a
    time-scaled copy for simulation only."""
    config_path = Path(config_path or PHASE7_CONFIG_PATH).resolve()
    table = load_sequence(config_path, PHASE7_LOOPBACK, scale)
    doc = yaml.safe_load(config_path.read_text()) or {}
    tg = table.target
    steps = list(table.steps) + [table.steps[-1]] * (SEQ_MAX_STEPS - len(table.steps))
    try:
        src = config_path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        src = config_path.name

    def L(name, w, values, comment=""):
        c = f"  // {comment}" if comment else ""
        return f"    localparam logic [{SEQ_MAX_STEPS * w - 1}:0] {name} = {_packed(values, w)};{c}"

    lines = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --phase7 -- do not edit by hand.",
        f"// Source: {src}" + (f"  (TIME-SCALED x{scale:g}: SIMULATION ONLY)" if scale != 1.0 else ""),
        "// Regenerate with: cd tools && python3 -m nemo_ctl.gen_svh --phase7",
        "// Steps (validated by sequence.compile_steps before writing):",
        *[f"//   {s}" for s in table.summary()],
        "`ifndef PHASE7_CFG_PKG_SV",
        "`define PHASE7_CFG_PKG_SV",
        "",
        "`timescale 1ns / 1ps",
        "",
        "package phase7_cfg_pkg;",
        f"    localparam int TICK_W = {TICK_W};",
        f"    localparam int N_SIG = {len(tg.sig_cells)};",
        f"    localparam int N_CAP = {len(tg.cap_cells)};",
        f"    localparam int STEP_W = 4;  // {SEQ_MAX_STEPS} steps max",
        f"    localparam logic [4:0] N_STEPS = 5'd{len(table.steps)};",
        f"    // time scale x{scale:g}" + (" -- SIMULATION ONLY" if scale != 1.0 else " (hardware)"),
        "",
        "    // ---- step table: mask bit i = cell i; COND 0=after 1=done 2=captured 3=edges 4=level ----",
        L("STEP_SIG_MASK", len(tg.sig_cells),
          [sum(int(m) << i for i, m in enumerate(s.sig_mask)) for s in steps]),
        L("STEP_CAP_MASK", len(tg.cap_cells),
          [sum(int(m) << i for i, m in enumerate(s.cap_mask)) for s in steps]),
        L("STEP_COND", 3, [s.cond for s in steps]),
        L("STEP_COND_CELL", 8, [s.cond_cell for s in steps]),
        L("STEP_COND_ARG", TICK_W, [s.cond_arg for s in steps]),
        L("STEP_TIMEOUT", TICK_W, [s.timeout for s in steps]),
        "",
    ]
    for i, spec in enumerate(tg.sig_cells):
        n = spec.name.upper()
        cfgs = [s.sig[i] for s in steps]
        lines += [
            f"    // sig cell {i}: {spec.name} (FMC pin {i})",
            L(f"{n}_TYPE", 3, [c.type for c in cfgs]),
            L(f"{n}_IDLE", 1, [c.idle for c in cfgs]),
            L(f"{n}_DELAY", TICK_W, [c.delay for c in cfgs]),
            L(f"{n}_PARAM_A", TICK_W, [c.param_a for c in cfgs]),
            L(f"{n}_PARAM_B", TICK_W, [c.param_b for c in cfgs]),
            L(f"{n}_CYCLES", TICK_W, [c.cycles for c in cfgs]),
            L(f"{n}_MSB_FIRST", 1, [c.msb_first for c in cfgs]),
            L(f"{n}_DATA", spec.serial_w, [c.data for c in cfgs]),
            L(f"{n}_BITS", TICK_W, [c.bits for c in cfgs]),
            "",
        ]
    for i, spec in enumerate(tg.cap_cells):
        n = spec.name.upper()
        cfgs = [s.cap[i] for s in steps]
        lines += [
            f"    // cap cell {i}: {spec.name} (FMC pin {i + 16})",
            L(f"{n}_MODE", 2, [c.mode for c in cfgs]),
            L(f"{n}_MSB_FIRST", 1, [c.msb_first for c in cfgs]),
            L(f"{n}_BITS", TICK_W, [c.bits for c in cfgs]),
            "",
        ]
    # expected SERIAL capture (LD6 / testbench)
    exp = (doc.get("expect") or {}).get("data_in")
    di = tg.cap_index("data_in")
    bits = steps[0].cap[di].bits
    for s in table.steps:
        if s.cap_mask[di]:
            bits = s.cap[di].bits
    if exp is None:
        raise GenError("phase7 config needs expect: {data_in: ...}")
    exp_v = int(exp, 0) if isinstance(exp, str) else int(exp)
    cap_w = tg.cap_cells[di].cap_w
    if not 0 <= exp_v < (1 << bits):
        raise GenError(f"expect data_in {exp_v:#x} doesn't fit the {bits}-bit capture")
    lines += [
        "    // what data_in must hold after its last SERIAL capture (cap_cell msb_first with",
        "    // bits < CAP_W lands at the bottom bits)",
        f"    localparam logic [{cap_w - 1}:0] DATA_IN_EXPECT = {cap_w}'h{exp_v:0{cap_w // 4}x};",
        f"    localparam logic [{cap_w - 1}:0] DATA_IN_EXPECT_MASK = {cap_w}'h{(1 << bits) - 1:0{cap_w // 4}x};",
        "endpackage",
        "",
        "`endif // PHASE7_CFG_PKG_SV",
        "",
    ]
    return "\n".join(lines), table.warnings


def generate_phase7_link() -> str:
    """phase7_link_pkg: where each field sits in a step entry (byte offsets) and the
    link v2 register map, for the PHASE7_LOOPBACK cell set. The RTL slices fields out of
    seq_bank's next_entry at bit 8 * byte."""
    tg = PHASE7_LOOPBACK
    lay = entry_layout(tg)
    lines = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --phase7-link -- do not edit by hand.",
        "// Step-entry byte layout: tools/nemo_ctl/sequence.py entry_layout(); register map:",
        "// docs/link_register_map.md (v2). The table itself arrives over the link.",
        "`ifndef PHASE7_LINK_PKG_SV",
        "`define PHASE7_LINK_PKG_SV",
        "",
        "`timescale 1ns / 1ps",
        "",
        "package phase7_link_pkg;",
        f"    localparam int N_SIG = {len(tg.sig_cells)};",
        f"    localparam int N_CAP = {len(tg.cap_cells)};",
        "    localparam int STEP_W = 4;",
        f"    localparam int ENTRY_BYTES = {ENTRY_BYTES};",
        f"    localparam int USED_BYTES = {lay.used_bytes};",
        f"    localparam int HDR_BYTES = {lay.hdr_bytes};",
        "",
        "    // ---- link v2 register map ----",
        f"    localparam logic [15:0] REG_STATUS = 16'h{V2_STATUS:04x};",
        f"    localparam logic [15:0] REG_STEP = 16'h{V2_STEP:04x};",
        f"    localparam logic [15:0] REG_LAST_STEP = 16'h{V2_LAST_STEP:04x};",
        f"    localparam logic [15:0] REG_N_STEPS = 16'h{V2_N_STEPS:04x};",
        f"    localparam logic [15:0] CAP_BASE = 16'h{V2_CAP_BASE:04x};",
        f"    localparam int CAP_STRIDE = {v2_cap_stride(tg)};",
        f"    localparam int CAP_DATA = {V2_CAP_DATA};   // capture_reg's first byte in a cap block",
        f"    localparam int CAP_BYTES = {v2_cap_bytes(tg)};",
        f"    localparam logic [15:0] TABLE_BASE = 16'h{V2_TABLE_BASE:04x};",
        "",
        "    // ---- step header (byte offsets in an entry) ----",
        f"    localparam int H_SIG_MASK = {lay.sig_mask};",
        f"    localparam int H_CAP_MASK = {lay.cap_mask};",
        f"    localparam int H_COND = {lay.cond};",
        f"    localparam int H_COND_CELL = {lay.cond_cell};",
        f"    localparam int H_COND_ARG = {lay.cond_arg};",
        f"    localparam int H_TIMEOUT = {lay.timeout};",
        "",
        "    // ---- field offsets inside a sig / cap cell block ----",
        f"    localparam int F_SIG_CTRL = {lay.SIG_CTRL};",
        f"    localparam int F_SIG_DELAY = {lay.SIG_DELAY};",
        f"    localparam int F_SIG_PARAM_A = {lay.SIG_PARAM_A};",
        f"    localparam int F_SIG_PARAM_B = {lay.SIG_PARAM_B};",
        f"    localparam int F_SIG_CYCLES = {lay.SIG_CYCLES};",
        f"    localparam int F_SIG_BITS = {lay.SIG_BITS};",
        f"    localparam int F_SIG_DATA = {lay.SIG_DATA};",
        f"    localparam int F_CAP_CTRL = {lay.CAP_CTRL};",
        f"    localparam int F_CAP_BITS = {lay.CAP_BITS};",
        "",
        "    // ---- where each cell's block starts ----",
    ]
    for i, c in enumerate(tg.sig_cells):
        lines.append(f"    localparam int {c.name.upper()}_BASE = {lay.sig_base[i]};   "
                     f"// sig cell {i}, SERIAL_W {c.serial_w}")
    for i, c in enumerate(tg.cap_cells):
        lines.append(f"    localparam int {c.name.upper()}_BASE = {lay.cap_base[i]};   "
                     f"// cap cell {i}, CAP_W {c.cap_w}")
    lines += ["endpackage", "", "`endif // PHASE7_LINK_PKG_SV", ""]
    return "\n".join(lines)


def phase7_table_image(config_path: Path | None = None, scale: float = 1.0) -> tuple[list[int], int]:
    """(16 x ENTRY_BYTES byte image of the encoded table, number of steps)."""
    table = load_sequence(Path(config_path or PHASE7_CONFIG_PATH), PHASE7_LOOPBACK, scale)
    lay = entry_layout(table.target)
    img = [0] * (SEQ_MAX_STEPS * ENTRY_BYTES)
    for k, st in enumerate(table.steps):
        img[k * ENTRY_BYTES:k * ENTRY_BYTES + lay.used_bytes] = encode_step(st, lay)
    return img, len(table.steps)


def phase7_table_package(config_path: Path | None = None, scale: float = 1.0) -> str:
    """The encoded table as package phase7_link_tb_pkg (byte b at TABLE[b*8 +: 8],
    N_STEPS steps): what the testbench sends over the link. Simulation only."""
    img, n = phase7_table_image(config_path, scale)
    used = img[:n * ENTRY_BYTES]
    value = int.from_bytes(bytes(used), "little")
    return "\n".join([
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --phase7-link --table-out -- SIMULATION ONLY.",
        f"// config/phase7_seq_loopback.yaml encoded per sequence.entry_layout, time scale x{scale:g}.",
        "`timescale 1ns / 1ps",
        "package phase7_link_tb_pkg;",
        f"    localparam int N_STEPS = {n};",
        f"    localparam logic [{len(used) * 8 - 1}:0] TABLE = {len(used) * 8}'h{value:0{len(used) * 2}x};",
        "endpackage",
        "",
    ])


# ======================================================================================
# Chip pipeline step C3: the chip top's package + XDC, both from config/nemo_config.yaml
# ======================================================================================

# clk / LED lines, copied unchanged from the verified link-top XDCs
# (fpga/constraints/phase7_link_jtag_top.xdc); test_gen_chip.py checks they still match.
BOARD_XDC_LINES = (
    "set_property PACKAGE_PIN Y9 [get_ports {clk}]",
    "set_property IOSTANDARD LVCMOS33 [get_ports {clk}]",
    "create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports {clk}]",
    "set_property PACKAGE_PIN T22 [get_ports {led[0]}]",
    "set_property PACKAGE_PIN T21 [get_ports {led[1]}]",
    "set_property PACKAGE_PIN U22 [get_ports {led[2]}]",
    "set_property PACKAGE_PIN U21 [get_ports {led[3]}]",
    "set_property PACKAGE_PIN V22 [get_ports {led[4]}]",
    "set_property PACKAGE_PIN W22 [get_ports {led[5]}]",
    "set_property PACKAGE_PIN U19 [get_ports {led[6]}]",
    "set_property PACKAGE_PIN U14 [get_ports {led[7]}]",
    "set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]",
)


def _chip_pin_map(config_path: Path) -> dict[str, str]:
    """The config's pin_map, refused unless every chip signal has a valid, unique pin."""
    from .config import load_config
    from .pins import load_pin_db
    from .validate import validate_config
    cfg = load_config(config_path)
    bad = [str(i) for i in validate_config(cfg, load_pin_db()) if i.mode == "pin_map" and
           (i.level == "error" or "missing" in i.message or "no FMC pin" in i.message)]
    if bad:
        raise GenError("pin_map not complete / valid, nothing written:\n  " + "\n  ".join(bad))
    return dict(cfg.pin_map)


def generate_chip(config_path: Path | None = None,
                  sipo_data_edge: str = "falling", piso_sample_edge: str = "falling") -> tuple[str, str]:
    """(chip_pkg.sv text, chip_top.xdc text) for the chip top (chip pipeline C3/C4).

    Cell order = sequence.chip_target() = pin_db order. chip_top.sv's ports are
    `chip_out[i]` = sig cell i (drives a chip input) and `chip_in[j]` = cap cell j (reads a
    chip output). The XDC gives each its FMC pin from the config's pin_map, the package pin
    from fmc_pins.py (= the verified mapping), and the rule of docs/decisions.md: DRIVE 4 +
    SLEW SLOW on every FPGA output that drives the chip; PULLDOWN on the inputs, so a pin
    with no chip on it reads 0.
    """
    from .fmc_pins import FMC_PINS
    from .sequence import chip_target
    config_path = Path(config_path or CHIP_CONFIG_PATH)
    pin_map = _chip_pin_map(config_path)
    tg = chip_target(sipo_data_edge, piso_sample_edge)
    lay = entry_layout(tg)
    try:
        src = config_path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        src = config_path.as_posix()

    def arr(vals):
        return "'{" + ", ".join(str(v) for v in vals) + "}"

    sipo_i, piso_j = tg.sig_index("sipo_in"), tg.cap_index("piso_out")
    sipo, piso = tg.sig_cells[sipo_i], tg.cap_cells[piso_j]
    sig_la = [FMC_PINS[pin_map[c.name]].la for c in tg.sig_cells]
    cap_la = [FMC_PINS[pin_map[c.name]].la for c in tg.cap_cells]
    pkg = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --chip -- do not edit by hand.",
        f"// Source: {src} (pin_map) + tools/nemo_ctl/sequence.py chip_target() (cells, layout).",
        "// Regenerate with: cd tools && python -m nemo_ctl.gen_svh --chip",
        "`ifndef CHIP_PKG_SV",
        "`define CHIP_PKG_SV",
        "",
        "`timescale 1ns / 1ps",
        "",
        "package chip_pkg;",
        f"    localparam int N_SIG = {len(tg.sig_cells)};   // chip inputs = chip_out[N_SIG-1:0]",
        f"    localparam int N_CAP = {len(tg.cap_cells)};    // chip outputs = chip_in[N_CAP-1:0]",
        "    localparam int STEP_W = 4;",
        f"    localparam int ENTRY_BYTES = {tg.entry_bytes};",
        f"    localparam int USED_BYTES = {lay.used_bytes};",
        f"    localparam int HDR_BYTES = {lay.hdr_bytes};",
        "",
        "    // ---- link v2 register map (docs/link_register_map.md) ----",
        f"    localparam logic [15:0] REG_STATUS = 16'h{V2_STATUS:04x};",
        f"    localparam logic [15:0] REG_STEP = 16'h{V2_STEP:04x};",
        f"    localparam logic [15:0] REG_LAST_STEP = 16'h{V2_LAST_STEP:04x};",
        f"    localparam logic [15:0] REG_N_STEPS = 16'h{V2_N_STEPS:04x};",
        f"    localparam logic [15:0] CAP_BASE = 16'h{V2_CAP_BASE:04x};",
        f"    localparam int CAP_STRIDE = {v2_cap_stride(tg)};",
        f"    localparam int CAP_DATA = {V2_CAP_DATA};   // capture_reg's first byte in a cap block",
        f"    localparam int CAP_BYTES = {v2_cap_bytes(tg)};",
        f"    localparam logic [15:0] TABLE_BASE = 16'h{V2_TABLE_BASE:04x};",
        "",
        "    // ---- step header / cell-block field offsets (bytes) ----",
        f"    localparam int H_SIG_MASK = {lay.sig_mask};",
        f"    localparam int H_CAP_MASK = {lay.cap_mask};",
        f"    localparam int H_COND = {lay.cond};",
        f"    localparam int H_COND_CELL = {lay.cond_cell};",
        f"    localparam int H_COND_ARG = {lay.cond_arg};",
        f"    localparam int H_TIMEOUT = {lay.timeout};",
        f"    localparam int F_SIG_CTRL = {lay.SIG_CTRL};",
        f"    localparam int F_SIG_DELAY = {lay.SIG_DELAY};",
        f"    localparam int F_SIG_PARAM_A = {lay.SIG_PARAM_A};",
        f"    localparam int F_SIG_PARAM_B = {lay.SIG_PARAM_B};",
        f"    localparam int F_SIG_CYCLES = {lay.SIG_CYCLES};",
        f"    localparam int F_SIG_BITS = {lay.SIG_BITS};",
        f"    localparam int F_SIG_DATA = {lay.SIG_DATA};",
        f"    localparam int F_CAP_CTRL = {lay.CAP_CTRL};",
        f"    localparam int F_CAP_BITS = {lay.CAP_BITS};",
        "",
        "    // ---- per cell, in chip_target() order (index = chip_out / chip_in bit) ----",
        f"    localparam int SIG_BASE [N_SIG] = {arr(lay.sig_base)};",
        f"    localparam int SIG_SERIAL_W [N_SIG] = {arr(c.serial_w for c in tg.sig_cells)};",
        f"    localparam int CAP_BLOCK [N_CAP] = {arr(lay.cap_base)};",
        f"    localparam int CAP_W [N_CAP] = {arr(c.cap_w for c in tg.cap_cells)};",
        f"    localparam int SIG_LA [N_SIG] = {arr(sig_la)};   // FMC LAxx_P of each chip_out (reference)",
        f"    localparam int CAP_LA [N_CAP] = {arr(cap_la)};   // FMC LAxx_P of each chip_in (reference)",
        "",
        "    // ---- the two serial cells and their strobes (edges UNCONFIRMED, Dima) ----",
        f"    localparam int SIPO_CELL = {sipo_i};       // sipo_in, SERIAL_W {sipo.serial_w}",
        f"    localparam int SIPO_CLK_CELL = {tg.sig_index(sipo.strobe[0])};    // {sipo.strobe[0]}",
        f"    localparam bit SIPO_ON_FALLING = 1'b{int(sipo.strobe[1] == 'falling')};   // {sipo.strobe[1]}",
        f"    localparam int PISO_CELL = {piso_j};        // piso_out, CAP_W {piso.cap_w}",
        f"    localparam int PISO_CLK_CELL = {tg.sig_index(piso.strobe[0])};    // {piso.strobe[0]}",
        f"    localparam bit PISO_ON_FALLING = 1'b{int(piso.strobe[1] == 'falling')};   // {piso.strobe[1]}",
        "",
        "    // ---- cell names, for reference ----",
    ]
    for i, c in enumerate(tg.sig_cells):
        pkg.append(f"    localparam int SIG_{c.name.upper()} = {i};   // -> {pin_map[c.name]}")
    for j, c in enumerate(tg.cap_cells):
        pkg.append(f"    localparam int CAP_{c.name.upper()} = {j};   // <- {pin_map[c.name]}")
    pkg += ["endpackage", "", "`endif // CHIP_PKG_SV", ""]

    xdc = [
        "## AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --chip -- do not edit by hand.",
        f"## Source: {src} (pin_map); package pins from tools/nemo_ctl/fmc_pins.py (= the verified",
        "## XDC mapping, CLAUDE.md §5). Regenerate with: cd tools && python -m nemo_ctl.gen_svh --chip",
        "## chip_out[i] drives chip input i, chip_in[j] reads chip output j (order: chip_pkg.sv).",
        "## Rule (docs/decisions.md 2026-10-26): DRIVE 4 + SLEW SLOW on every FPGA output that drives",
        "## the chip; PULLDOWN on the inputs, so a pin without the chip reads 0.",
        "",
        "## ---- 100 MHz system clock and LD0-LD7 (verified lines, phase7_link_jtag_top.xdc) ----",
        *BOARD_XDC_LINES,
        "",
        "## ---- FPGA outputs -> chip inputs ----",
    ]
    for i, c in enumerate(tg.sig_cells):
        f = FMC_PINS[pin_map[c.name]]
        xdc.append(f"## {c.name} -> {f.name} ({f.header})")
        xdc.append(f"set_property PACKAGE_PIN {f.package_pin} [get_ports {{chip_out[{i}]}}]")
    xdc += [
        "set_property IOSTANDARD LVCMOS18 [get_ports {chip_out[*]}]",
        "set_property DRIVE 4 [get_ports {chip_out[*]}]",
        "set_property SLEW SLOW [get_ports {chip_out[*]}]",
        "",
        "## ---- chip outputs -> FPGA inputs ----",
    ]
    for j, c in enumerate(tg.cap_cells):
        f = FMC_PINS[pin_map[c.name]]
        xdc.append(f"## {c.name} <- {f.name} ({f.header})")
        xdc.append(f"set_property PACKAGE_PIN {f.package_pin} [get_ports {{chip_in[{j}]}}]")
    xdc += [
        "set_property IOSTANDARD LVCMOS18 [get_ports {chip_in[*]}]",
        "set_property PULLDOWN true [get_ports {chip_in[*]}]",
        "",
        "## ---- JTAG TCK from the BSCANE2 primitive (the PC link, as in phase7_link_jtag_top.xdc) ----",
        "create_clock -name jtag_tck -period 33.333 [get_pins -hierarchical *u_bscan/TCK]",
        "set_clock_groups -asynchronous -group [get_clocks sys_clk_pin] -group [get_clocks jtag_tck]",
        "",
    ]
    return "\n".join(pkg), "\n".join(xdc)


# ---- chip pipeline C6 / EXP-08: vchip_top = chip_top + Dima's SIPO/PISO as a virtual chip ----
# fixed order of vchip_top.sv's vc_in / vc_out ports
VCHIP_IN = ("sipo_in", "clk_sipo", "cs", "rst_sipo", "clk_piso", "shift", "rst_piso", "phirst")
VCHIP_OUT = ("sipo_out", "piso_out")
VCHIP_CLOCKS = ("clk_sipo", "cs", "clk_piso", "phirst")   # the virtual chip's pad clocks
VCHIP_CLOCK_PERIOD_NS = 1000.0                             # 1 MHz, the rate chip_sim_test.yaml uses


def _vchip_dft_cells() -> set[str]:
    from .groups import PIN_GROUPS
    return set(PIN_GROUPS["b_dft"]) | set(PIN_GROUPS["s_dft"])


def generate_vchip(config_path: Path | None = None, vchip_path: Path | None = None) -> tuple[str, str]:
    """(vchip_pkg.sv text, vchip_top.xdc text) for vchip_top (EXP-08).

    The controller part is chip_top with its pins from the config's pin_map, minus the 7 DFT
    outputs (pin budget): ctl_out[k] = chip_out[CTL_SIG[k]]. The virtual chip's pins and the
    jumper table come from config/exp08_vchip.yaml. Refused if a pin is unknown, used twice,
    or a jumper doesn't connect a controller output to a virtual-chip input (or a
    virtual-chip output to a controller input).
    """
    from .fmc_pins import FMC_PINS
    from .sequence import chip_target
    config_path = Path(config_path or CHIP_CONFIG_PATH)
    vchip_path = Path(vchip_path or VCHIP_CONFIG_PATH)
    pin_map = _chip_pin_map(config_path)
    with open(vchip_path) as f:
        doc = yaml.safe_load(f) or {}
    vpins, jumpers = doc.get("vchip_pins") or {}, doc.get("jumpers") or {}
    names = VCHIP_IN + VCHIP_OUT
    for what, d in (("vchip_pins", vpins), ("jumpers", jumpers)):
        if set(d) != set(names):
            raise GenError(f"{vchip_path.name}: {what} must name exactly {', '.join(names)}")
    tg = chip_target()
    dft = _vchip_dft_cells()
    ctl_sig = [i for i, c in enumerate(tg.sig_cells) if c.name not in dft]
    ctl_names = [tg.sig_cells[i].name for i in ctl_sig]
    used = {pin_map[n]: f"controller {n}" for n in ctl_names}
    used.update({pin_map[c.name]: f"controller {c.name}" for c in tg.cap_cells})
    for n in names:
        p = vpins[n]
        if p not in FMC_PINS:
            raise GenError(f"{vchip_path.name}: virtual chip {n}: {p!r} is not an FMC LA_P pin")
        if p in used:
            raise GenError(f"{vchip_path.name}: virtual chip {n}: {p} already used by {used[p]}")
        used[p] = f"virtual chip {n}"
    cap_names = [c.name for c in tg.cap_cells]
    vc_src, vc_dst = [], []
    for n in VCHIP_IN:
        if jumpers[n] not in ctl_names:
            raise GenError(f"{vchip_path.name}: jumper to virtual chip {n} must come from a pinned "
                           f"controller output (not {jumpers[n]!r}; DFT outputs aren't pinned)")
        vc_src.append(ctl_names.index(jumpers[n]))
    for n in VCHIP_OUT:
        if jumpers[n] not in cap_names:
            raise GenError(f"{vchip_path.name}: jumper from virtual chip {n} must go to a controller "
                           f"input ({', '.join(cap_names)}), not {jumpers[n]!r}")
        vc_dst.append(cap_names.index(jumpers[n]))

    def src_of(p: Path) -> str:
        try:
            return p.resolve().relative_to(REPO_ROOT).as_posix()
        except ValueError:
            return p.as_posix()

    def arr(vals):
        return "'{" + ", ".join(str(v) for v in vals) + "}"

    hdr = (f"Source: {src_of(config_path)} (pin_map) + {src_of(vchip_path)} (virtual chip pins, jumpers).",
           "Regenerate with: cd tools && python -m nemo_ctl.gen_svh --vchip")
    pkg = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --vchip -- do not edit by hand.",
        f"// {hdr[0]}", f"// {hdr[1]}",
        "`ifndef VCHIP_PKG_SV",
        "`define VCHIP_PKG_SV",
        "",
        "`timescale 1ns / 1ps",
        "",
        "package vchip_pkg;",
        f"    localparam int N_CTL = {len(ctl_sig)};   // chip_top outputs on a pin (the 7 DFT ones are not)",
        f"    localparam int CTL_SIG [N_CTL] = {arr(ctl_sig)};   // ctl_out[k] = chip_out[CTL_SIG[k]]",
        "    // the jumpers (testbench / reference): vc_in[k] <- ctl_out[VC_SRC[k]], vc_out[k] -> ctl_in[VC_DST[k]]",
        f"    localparam int VC_SRC [{len(VCHIP_IN)}] = {arr(vc_src)};   // {', '.join(VCHIP_IN)}",
        f"    localparam int VC_DST [{len(VCHIP_OUT)}] = {arr(vc_dst)};   // {', '.join(VCHIP_OUT)}",
        "endpackage",
        "",
        "`endif // VCHIP_PKG_SV",
        "",
    ]

    xdc = [
        "## AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --vchip -- do not edit by hand.",
        f"## {hdr[0]}", f"## {hdr[1]}",
        "## vchip_top = chip_top (controller) + virtual_chip (Dima's SIPO/PISO RTL), EXP-08.",
        "## Package pins from tools/nemo_ctl/fmc_pins.py (= the verified XDC mapping, CLAUDE.md §5).",
        "## Rule (docs/decisions.md 2026-10-26): DRIVE 4 + SLEW SLOW on outputs, PULLDOWN on inputs.",
        "##",
        "## Jumper wires (HTG-FMC headers, P column):",
    ]
    for n in VCHIP_IN:
        c, v = FMC_PINS[pin_map[jumpers[n]]], FMC_PINS[vpins[n]]
        xdc.append(f"##   {c.header:6} {jumpers[n]:9} -> {v.header:6} virtual chip {n}")
    for n in VCHIP_OUT:
        c, v = FMC_PINS[pin_map[jumpers[n]]], FMC_PINS[vpins[n]]
        xdc.append(f"##   {c.header:6} {jumpers[n]:9} <- {v.header:6} virtual chip {n}")
    xdc += [
        "",
        "## ---- 100 MHz system clock and LD0-LD7 (verified lines, phase7_link_jtag_top.xdc) ----",
        *BOARD_XDC_LINES,
        "",
        "## ---- controller outputs (chip_top chip_out minus DFT) ----",
    ]
    for k, i in enumerate(ctl_sig):
        f = FMC_PINS[pin_map[tg.sig_cells[i].name]]
        xdc.append(f"## {tg.sig_cells[i].name} -> {f.name} ({f.header})")
        xdc.append(f"set_property PACKAGE_PIN {f.package_pin} [get_ports {{ctl_out[{k}]}}]")
    xdc += [
        "set_property IOSTANDARD LVCMOS18 [get_ports {ctl_out[*]}]",
        "set_property DRIVE 4 [get_ports {ctl_out[*]}]",
        "set_property SLEW SLOW [get_ports {ctl_out[*]}]",
        "",
        "## ---- controller inputs (chip_top chip_in) ----",
    ]
    for j, c in enumerate(tg.cap_cells):
        f = FMC_PINS[pin_map[c.name]]
        xdc.append(f"## {c.name} <- {f.name} ({f.header})")
        xdc.append(f"set_property PACKAGE_PIN {f.package_pin} [get_ports {{ctl_in[{j}]}}]")
    xdc += [
        "set_property IOSTANDARD LVCMOS18 [get_ports {ctl_in[*]}]",
        "set_property PULLDOWN true [get_ports {ctl_in[*]}]",
        "",
        "## ---- virtual chip inputs (PULLDOWN: a missing jumper holds its resets low = in reset) ----",
    ]
    for k, n in enumerate(VCHIP_IN):
        f = FMC_PINS[vpins[n]]
        xdc.append(f"## virtual chip {n} <- {f.name} ({f.header})")
        xdc.append(f"set_property PACKAGE_PIN {f.package_pin} [get_ports {{vc_in[{k}]}}]")
    xdc += [
        "set_property IOSTANDARD LVCMOS18 [get_ports {vc_in[*]}]",
        "set_property PULLDOWN true [get_ports {vc_in[*]}]",
        "",
        "## ---- virtual chip outputs ----",
    ]
    for k, n in enumerate(VCHIP_OUT):
        f = FMC_PINS[vpins[n]]
        xdc.append(f"## virtual chip {n} -> {f.name} ({f.header})")
        xdc.append(f"set_property PACKAGE_PIN {f.package_pin} [get_ports {{vc_out[{k}]}}]")
    xdc += [
        "set_property IOSTANDARD LVCMOS18 [get_ports {vc_out[*]}]",
        "set_property DRIVE 4 [get_ports {vc_out[*]}]",
        "set_property SLEW SLOW [get_ports {vc_out[*]}]",
        "",
        "## ---- the virtual chip's pad clocks (as on the chip) ----",
        "## They arrive on ordinary LA_P pins, not clock-capable ones, so the route to the global",
        f"## clock buffer is not dedicated: allowed here, the clocks are slow ({VCHIP_CLOCK_PERIOD_NS:g} ns).",
    ]
    groups = []
    for n in VCHIP_CLOCKS:
        k = VCHIP_IN.index(n)
        xdc.append(f"create_clock -name vc_{n} -period {VCHIP_CLOCK_PERIOD_NS:.3f} [get_ports {{vc_in[{k}]}}]")
        xdc.append(f"set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets {{vc_in_IBUF[{k}]}}]")
        groups.append(f"-group [get_clocks vc_{n}]")
    xdc += [
        "",
        "## ---- JTAG TCK from the BSCANE2 primitive (the PC link, as in phase7_link_jtag_top.xdc) ----",
        "create_clock -name jtag_tck -period 33.333 [get_pins -hierarchical *u_bscan/TCK]",
        "## every clock is independent of the others (the virtual chip's are separate pads)",
        "set_clock_groups -asynchronous -group [get_clocks sys_clk_pin] -group [get_clocks jtag_tck] "
        + " ".join(groups),
        "",
    ]
    return "\n".join(pkg), "\n".join(xdc)


def chip_table_package(seq_path: Path | None = None) -> str:
    """A chip-target sequence encoded as package chip_tb_pkg (byte b of step k at
    TABLE[(k * ENTRY_BYTES + b) * 8 +: 8]): what fpga/tb/chip_top_tb.sv sends over the link.
    Also the data the testbench checks against (SIPO frame, PISO width). SIMULATION ONLY."""
    from .sequence import chip_target, load_sequence
    seq_path = Path(seq_path or CHIP_SIM_SEQ_PATH)
    tg = chip_target()
    table = load_sequence(seq_path, tg)
    lay = entry_layout(tg)
    img = bytearray(len(table.steps) * tg.entry_bytes)
    for k, st in enumerate(table.steps):
        img[k * tg.entry_bytes:k * tg.entry_bytes + lay.used_bytes] = encode_step(st, lay)
    value = int.from_bytes(bytes(img), "little")
    i = tg.sig_index("sipo_in")
    loads = [st for st in table.steps if st.sig_mask[i] and st.sig[i].type == 4]
    sipo = loads[0].sig[i] if loads else None
    try:
        src = seq_path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        src = seq_path.as_posix()
    lines = [
        "// AUTO-GENERATED by tools/nemo_ctl/gen_svh.py --chip --table-out -- SIMULATION ONLY.",
        f"// {src} encoded per sequence.entry_layout(chip_target()).",
        "`timescale 1ns / 1ps",
        "package chip_tb_pkg;",
        f"    localparam int N_STEPS = {len(table.steps)};",
        f"    localparam int USED_BYTES = {lay.used_bytes};",
        f"    localparam logic [{len(img) * 8 - 1}:0] TABLE = {len(img) * 8}'h{value:0{len(img) * 2}x};",
    ]
    if sipo is not None:
        w = tg.sig_cells[i].serial_w
        # sig_cell holds msb_first data MSB-justified in SERIAL_W; with bits == SERIAL_W it's the frame
        lines += [f"    localparam int SIPO_BITS_SENT = {sipo.bits};",
                  f"    localparam logic [{w - 1}:0] SIPO_FRAME = {w}'h{sipo.data:0{w // 4}x};"]
    lines += ["endpackage", ""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(
        prog="python -m nemo_ctl.gen_svh",
        description="Generate a top level's compile-time config package: "
                    "phase4_loopback_top's nemo_cfg_pkg.sv (default), "
                    "phase6_sipo_piso_top's phase6_cfg_pkg.sv (--phase6) or "
                    "phase7_seq_loopback_top's phase7_cfg_pkg.sv (--phase7).")
    which = ap.add_mutually_exclusive_group()
    which.add_argument("--phase6", action="store_true",
                       help="config/phase6_sipo_piso.yaml -> fpga/src/gen/phase6_cfg_pkg.sv")
    which.add_argument("--phase7", action="store_true",
                       help="config/phase7_seq_loopback.yaml -> fpga/src/gen/phase7_cfg_pkg.sv")
    which.add_argument("--phase7-link", action="store_true",
                       help="step-entry layout + link v2 map -> fpga/src/gen/phase7_link_pkg.sv")
    which.add_argument("--chip", action="store_true",
                       help="config/nemo_config.yaml (pin_map) -> fpga/src/gen/chip_pkg.sv + "
                            "fpga/constraints/chip_top.xdc (the chip top)")
    which.add_argument("--vchip", action="store_true",
                       help="pin_map + config/exp08_vchip.yaml -> fpga/src/gen/vchip_pkg.sv + "
                            "fpga/constraints/vchip_top.xdc (EXP-08, chip_top + virtual chip)")
    ap.add_argument("--table-out", type=Path, default=None,
                    help="--phase7-link: also write config/phase7_seq_loopback.yaml's encoded "
                         "table here as package phase7_link_tb_pkg (simulation), at --time-scale; "
                         "--chip: write config/chip_sim_test.yaml's encoded table here as package "
                         "chip_tb_pkg (simulation) INSTEAD of the chip package / XDC")
    ap.add_argument("--seq", type=Path, default=None,
                    help="--chip --table-out: encode this chip_top sequence instead of "
                         "config/chip_sim_test.yaml (e.g. config/exp08_phirst.yaml)")
    ap.add_argument("--time-scale", type=float, default=1.0,
                    help="--phase7 only: multiply every time by this (e.g. 1e-4) for a "
                         "simulation copy; use with --out, never for the hardware package")
    ap.add_argument("--out", type=Path, default=None,
                    help="--phase7 only: write here instead of fpga/src/gen/phase7_cfg_pkg.sv")
    args = ap.parse_args(argv)
    if args.out and not args.phase7:
        ap.error("--out only applies to --phase7")
    if args.seq and not (args.chip and args.table_out):
        ap.error("--seq only applies to --chip --table-out")
    if args.table_out and not (args.phase7_link or args.chip):
        ap.error("--table-out only applies to --phase7-link or --chip")
    if args.time_scale != 1.0 and not (args.phase7 or args.table_out):
        ap.error("--time-scale only applies to --phase7 or --phase7-link --table-out")
    if args.phase7 and args.time_scale != 1.0 and args.out is None:
        ap.error("a time-scaled package is for simulation only: give --out (outside fpga/src/gen)")
    out, warnings = OUT_PATH, ()
    try:
        if args.phase6:
            out = PHASE6_OUT_PATH
            text, warnings = generate_phase6()
        elif args.phase7:
            out = args.out or PHASE7_OUT_PATH
            text, warnings = generate_phase7(scale=args.time_scale)
        elif args.chip and args.table_out:
            out, text = args.table_out, chip_table_package(args.seq)
        elif args.chip:
            pkg_text, xdc_text = generate_chip()
            CHIP_XDC_OUT_PATH.write_text(xdc_text)
            print(f"wrote {CHIP_XDC_OUT_PATH}")
            out, text = CHIP_PKG_OUT_PATH, pkg_text
        elif args.vchip:
            pkg_text, xdc_text = generate_vchip()
            VCHIP_XDC_OUT_PATH.write_text(xdc_text)
            print(f"wrote {VCHIP_XDC_OUT_PATH}")
            out, text = VCHIP_PKG_OUT_PATH, pkg_text
        elif args.phase7_link:
            out = PHASE7_LINK_OUT_PATH
            text = generate_phase7_link()
            if args.table_out:
                args.table_out.write_text(phase7_table_package(scale=args.time_scale))
                print(f"wrote {args.table_out}")
        else:
            text = generate()
    except (GenError, FrameError, SequenceError, UnitsError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
