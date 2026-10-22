# Generic NEMO chip controller — Phase 0 spec

Phase 0 of `generic_controller_prompt.md`. No code in this phase. Goal: pin table, config
schema, register map, link protocol draft, resource estimate, the disagreements between
the source sheets, and open questions — enough to approve a design direction before Phase 1.

## 0. Sources used (located this session)

| What the task brief asked for | File actually used | Notes |
|---|---|---|
| Blocks workbook, sheet "Blocks Interface - Digital" | `docs/reference/nemo_chip/Blocks.xlsx`, sheet **Blocks Interface - Digital** | Found as named. |
| Newest pinout workbook `IO_pinout2.xlsx`, sheet "IO-Pins-Dima" | `docs/reference/nemo_chip/IO_pinout.xlsx`, sheet **IO-Pins-Dima** | No file named `IO_pinout2.xlsx` exists. Per `docs/reference/nemo_chip/README.md` the repo file is `IO_pinout.xlsx`, imported from `IO_pinout(2).xlsx`. Same sheet also exists inside `Blocks.xlsx` (identical content, checked). Treated as the same source the brief meant. |
| Session1 explainer | `docs/session1/NEMO chip SIPO, PISO and Y-Flash modes explained.pdf` (+ `docs/session1/diagrams/01..06`) | Found as named; text extracted and read in full (13 pages). |
| `fpga/reference/dima_blocks/` (sipo.sv, sipo_wrapper.sv, piso.sv) | same path | Found as named; read in full. Not synthesized, reference only (per its own `README.md`). |

Other sheets opened while cross-checking: `Pinout_TO1`, `Pinout`, `Pinout_Dima`,
`Pinout_Dima (2)`, `Interface - Dima`, `SA_Interface_Nov`, `DFT` (all inside `Blocks.xlsx` /
`IO_pinout.xlsx`). Also read: `docs/pin_verification.md`, `docs/decisions.md`,
`docs/issues.md`, `fpga/constraints/PINS_layout.xdc`.

No `openpyxl`/`pandas` were available in the environment; both were installed locally
(`pip3 install openpyxl pypdf`) to read the `.xlsx`/`.pdf` sources. Nothing was read by eye
or guessed.

## 1. Cross-check: 22 inputs + 4 outputs

The session1 explainer states the expected count explicitly (page 1): *"22 inputs the FPGA
must drive and 4 outputs it must read, so 26 FMC pins in total (we have 32 verified)."*
Checked against the sheets — **neither sheet alone gives 22+4; each is missing something,
and the two disagree on names and pad numbers.** The correct 26-signal set only appears when
the two lists are unioned:

| Signal | In "Blocks Interface - Digital" (pad, of 1-68) | In "IO-Pins-Dima" (pin, of 1-67) |
|---|---|---|
| clk | 14 | 52 |
| reset | 63 | 28 |
| set | 24 | 32 |
| rst_dsa | 6 | 35 |
| pulse | 22 | 53 |
| s0_p / s1_p / s2_p | 11 / 12 / 13 (named `s0_p,s1_p,s2_p`) | 29 / 30 / 31 (named `s0,s1,s2` — **no `_p` suffix**) |
| b0_dft / b1_dft / b2_dft | 25 / 23 / 62 | 40 / 41 / 42 |
| s0_dft / s1_dft | 8 / 7 | 38 / 39 |
| s2_dft / s3_dft | 64 / 5 | **absent from this sheet** |
| sipo_in | 28 | 27 |
| clk_sipo | 29 | 26 |
| cs | 31 | 34 |
| rst_sipo | **absent from this sheet** (pad 39 on this sheet is "Unused") | 37 |
| clk_piso | 56 | 25 |
| shift | 57 | 33 |
| rst_piso | 59 | 36 |
| sipo_out (out) | 30 | 44 |
| piso_out (out) | 58 | 43 |
| dft0_buff (out) | 4 (named `dft0_buff`) | 54 (named `dft0`) |
| dft1_buff (out) | 66 (named `dft1_buff`) | 55 (named `dft1`) |
| PISO_WR | unnumbered row, sits between pad 22 and 23 | not present |

Union = 22 inputs (`clk, reset, set, rst_dsa, pulse, s0_p, s1_p, s2_p, b0_dft, b1_dft,
b2_dft, s0_dft, s1_dft, s2_dft, s3_dft, sipo_in, clk_sipo, cs, rst_sipo, clk_piso, shift,
rst_piso`) + 4 outputs (`sipo_out, piso_out, dft0_buff, dft1_buff`) = 26, matching the
explainer. **Both individual sheets are therefore incomplete or inconsistent on their own**
— see disagreements below. `PISO_WR` is excluded from the 26 (see disagreement list, item 6).

## 2. Disagreements found (reported, not resolved)

1. **`rst_sipo` missing from "Blocks Interface - Digital"**. It is pin 37 in "IO-Pins-Dima"'s
   numbered list, but on "Blocks Interface - Digital" (and the near-identical old draft
   "Pinout_Dima (2)") pad 39 is labeled "Unused" and no row anywhere on that sheet is named
   `rst_sipo`. This is the exact discrepancy flagged in the task brief ("rst_sipo is on pad
   39 of the pad ring but pin 39 is 'Unused' in the digital sheet") — confirmed, except the
   number found in IO-Pins-Dima's linear list is **37, not 39**. IO-Pins-Dima also contains a
   separate pictorial pad-ring floorplan (rows ~59-150 of that sheet, laid out as a grid of
   named pins rather than a numbered table) where `rst_sipo` appears again; we could not
   extract an unambiguous linear pad index from that drawing with a text-based read (no
   merge/position parsing done). **Open: true physical pad number of `rst_sipo` is
   unconfirmed — could be 37, 39, or something the floorplan drawing encodes differently.**
2. **`s2_dft` / `s3_dft` missing from "IO-Pins-Dima"**. "Blocks Interface - Digital" has four
   DFT-per-ADC select bits (`s0_dft..s3_dft`, pads 8,7,64,5). "IO-Pins-Dima" has only two
   (`s0_dft`, `s1_dft`, pins 38,39). Four bits would select 16 values, not the 8 values
   (`d0..d7`) the task brief's DFT lookup table needs; two bits would only select 4. Neither
   sheet's bit count for this select cleanly matches an 8-way mux. **UNCONFIRMED — ask Dima
   how many select bits actually exist and what the 8:1 table really is** (ties into item 5).
3. **Naming: `s0_p,s1_p,s2_p` vs `s0,s1,s2`.** "Blocks Interface - Digital" names the
   Array-with-Muxes control bits `s0_p,s1_p,s2_p`; "IO-Pins-Dima" names the same pin
   positions `s0,s1,s2` with no `_p` suffix. Session1 (page 1) explicitly notes this: *"the
   earlier pin list calls s0_p..s2_p simply s0..s2."* Treating these as the same 3 signals
   (per the explainer), but the rename is unconfirmed as deliberate vs. a typo.
4. **Two incompatible pad-numbering schemes.** "Blocks Interface - Digital" / "Pinout_Dima
   (2)" number every physical pad 1-68, including every repeated ground/power/analog-bias
   pad and empty "Unused" slots. "IO-Pins-Dima"'s linear table numbers only the signals it
   lists, 1-67, and groups many of the ground pins together at the top (pins 1-8) rather
   than interspersing them physically. These are not the same numbering space — a pad
   number from one sheet cannot be assumed to mean the same physical pad in the other.
5. **"Pinout_Dima (2)" is a stale duplicate.** Row-for-row identical (within rounding of
   blank cells) to "Blocks Interface - Digital". Treated per the task brief as an old draft
   and not used as an independent source — it does, however, independently corroborate
   "Blocks Interface - Digital"'s pad 39 = "Unused" and the unnumbered `PISO_WR` row.
6. **`PISO_WR` row — likely leftover from an unrelated, older pinout.** It sits unnumbered
   between pads 22 and 23 on "Blocks Interface - Digital" / "Pinout_Dima (2)", with only
   `Name` and `Direction=in` populated (no `Purpose`/`block`). Three other sheets in the same
   workbook — `Pinout_TO1`, `Pinout`, `Pinout_Dima` — describe a **different, SPI-based**
   digital interface for what looks like an earlier chip generation: `SCLK_CTRL, SDI_CTRL,
   SDO_CTRL, CS_CTRL, PISO_CLK, PISO_DATA, PISO_WR, PISO_RST, DATA<0:7>, CA<0:7>, CLKI/O_P/N,
   ANA<0:n>`. None of these names appear in the current chip's RTL (`sipo.sv`,
   `sipo_wrapper.sv`, `piso.sv`) or in the session1 explainer's pin table. **These three
   sheets, and the `PISO_WR` row they left behind on the newer sheets, are treated as not
   applicable to the current TD-ANN chip** — flagged here rather than silently dropped.
7. **Stand-alone test structure** (`reset_sa, set_sa, clk_sa, input_sa, s0_dft_sa,
   s1_dft_sa, piso_out_sa, dft_0_sa, dft_1_sa`) appears in "IO-Pins-Dima" (pins 45-51, 56-57)
   but, per session1 (page 3), is *not* in the latest pad ring. Excluded from the 26-signal
   controller scope; **open question whether it is still present on the chip at all.**

## 3. Reconciled pin table (26 digital signals)

Pad numbers shown as `digital-sheet#/io-pins-dima#` where they disagree (see §2). `—`
means absent from that sheet. FMC LA pin is **TBD for every signal** — no chip-pin → FMC
LA_P assignment exists anywhere in the repo yet; this is a Phase 1/4 decision, constrained
to the 32 verified LA_P pins (`docs/pin_verification.md`), of which only pair 0
(`LA00_P`/`LA16_P`) has a hardware-confirmed loopback so far — the other 31 pins'
physical-to-package mapping is known (XDC) but functionally untested.

### Clock Generator block

| Pin | Dir | Pad # | Allowed types | Safe limits | Idle level | Polarity | Notes |
|---|---|---|---|---|---|---|---|
| `clk` | in | 14/52 | CLOCK | max freq TBD (Q7); generic FPGA ceiling 50 MHz hard / 10 MHz warn ([issues.md](issues.md)) | LOW | — | Drives on-chip phi1/phi2/phiR generation ([Interface - Dima] sheet confirms Clk Gen outputs phi1/phi2/phir from clk/reset/set internally — matches CLAUDE.md §7 item 4: do not build phases in the FPGA). |
| `reset` | in | 63/28 | LOW / HIGH / PULSE | — | TBD | TBD (Q6) | Meaning/polarity "Ask Dima" per session1 p.2. |
| `set` | in | 24/32 | LOW / HIGH / PULSE | — | TBD | TBD (Q6) | Same — undocumented. |

### SIPO block

| Pin | Dir | Pad # | Allowed types | Safe limits | Idle level | Polarity | Notes |
|---|---|---|---|---|---|---|---|
| `sipo_in` | in | 28/27 | SERIAL (ref. `clk_sipo`) | SIPO_BITS=136, MSB-first (bit135 first, bit0 last) | LOW | — | Must change on the **falling** edge of `clk_sipo` so it's stable at the rising edge (session1 p.5). |
| `clk_sipo` | in | 29/26 | CLOCK | 136 edges then stop low; max freq TBD (Q7) | LOW | — | — |
| `cs` | in | 31/34 | PULSE (edge-triggered, not level) | one clean rising edge after the 136th `clk_sipo` edge | LOW | active-high edge (per RTL `clk_s`) | Glitch on this wire latches garbage — must come from a registered FF, never combinational (session1 p.4, CLAUDE.md §8). |
| `rst_sipo` | in | —/37 (pad number unconfirmed, see §2.1) | LOW / HIGH / PULSE | — | **HIGH** (inactive) | **active-low**, confirmed from RTL (`rst_n` in `sipo.sv`) | Whether active-low *at the pad* (vs. inverted somewhere) is still Q6. |
| `sipo_out` | out | 30/44 | CAPTURE (level or 1-bit serial vs. `clk_sipo`) | — | — | — | `shift_reg[0]`, a one-clock-late echo of `sipo_in`; use as an "is the chip alive" loopback check (session1 p.4), not a data output. |

### PISO block

| Pin | Dir | Pad # | Allowed types | Safe limits | Idle level | Polarity | Notes |
|---|---|---|---|---|---|---|---|
| `clk_piso` | in | 56/25 | CLOCK | 1 load edge + 167 shift edges = 168 total; max freq TBD (Q7) | LOW | — | — |
| `shift` | in | 57/33 | LOW / HIGH (level, set between edges) | — | TBD (likely LOW = sample, see note) | — | `0`=load/sample, `1`=shift (RTL `load`). Must be `0` during the one load edge, then set to `1` *while `clk_piso` is low*, before the first shift edge (session1 p.7). |
| `rst_piso` | in | 59/36 | LOW / HIGH / PULSE | — | **HIGH** (inactive) | **active-low**, confirmed from RTL | Same pad-vs-RTL caveat as `rst_sipo` (Q6). |
| `piso_out` | out | 58/43 | CAPTURE, N-bit serial vs. `clk_piso` | PISO_BITS=168, MSB-first, split 4×[14+7+14+7] | — | — | Bit 1 is already valid on `piso_out` right before any shift clocks (immediately after the load edge) — read it before clocking, or the whole frame shifts by one (session1 p.7). Sample on the **falling** edge of `clk_piso` thereafter (half-period margin). |

### Array with Muxes / DSA

| Pin | Dir | Pad # | Allowed types | Safe limits | Idle level | Polarity | Notes |
|---|---|---|---|---|---|---|---|
| `s0_p` / `s1_p` / `s2_p` (= `s0`/`s1`/`s2` on IO-Pins-Dima, §2.3) | in | 11/29, 12/30, 13/31 | BUS (3-bit value) or individual LOW/HIGH | — | TBD | TBD | "3 bits, likely operation/mode select — guess, confirm" (session1 p.2, Q6). |
| `pulse` | in | 22/53 | PULSE | width TBD (Q6, Q7) | TBD | TBD | "Probably the program/erase pulse timing" — guess, unconfirmed. |
| `rst_dsa` | in | 6/35 | LOW / HIGH / PULSE | — | TBD | TBD (Q6) | Clears the DSA shift-and-add accumulators. |

### DFT

| Pin | Dir | Pad # | Allowed types | Safe limits | Idle level | Polarity | Notes |
|---|---|---|---|---|---|---|---|
| `b0_dft` / `b1_dft` / `b2_dft` | in | 25/40, 23/41, 62/42 | BUS (3-bit) via DFT helper, or raw LOW/HIGH | — | TBD | — | Selects which "dft per ADC" pair reaches `dft0_buff`/`dft1_buff` (8:1 mux of pairs a..h). Lookup table **UNCONFIRMED** (§4). |
| `s0_dft` / `s1_dft` / `s2_dft` / `s3_dft` | in | 8/38, 7/39, 64/—, 5/— | BUS via DFT helper, or raw LOW/HIGH | — | TBD | — | Bit count disagreement — see §2.2. Selects `d0..d7` inside one "dft per ADC" mux. |
| `dft0_buff` / `dft1_buff` (named `dft0`/`dft1` on IO-Pins-Dima) | out | 4/54, 66/55 | CAPTURE (level / frequency+duty) | — | — | — | Buffered observation outputs; useful for "first-light" phi1/phi2 frequency check (CLAUDE.md §7 item... Phase 8 checklist). |

### Analog biases / supplies — NOT driven by the FPGA

`v_read, v_write, v_erase, vth, vcch_wl, vcch_bl, lvr_cm, lvr_vb, bl_vdc, tdc_vb, vtc_vb,
delta_vb, bl_pad/pad, vssx, vccx, vccy`. Listed for completeness; come from lab supplies,
kept out of the generic cell generators per the task brief.

### Excluded from the 26-signal scope (open, not implemented)

`PISO_WR` (§2.6, probably an unrelated/older-chip leftover), and the stand-alone test
structure `reset_sa, set_sa, clk_sa, input_sa, s0/1_dft_sa, piso_out_sa, dft_0/1_sa` (§2.7,
not on the latest pad ring per session1).

## 4. DFT helper lookup table — UNCONFIRMED

Per the task brief, carried forward unchanged (no additional confirmation found in the
`DFT` sheet, which only lists analog sense/force signal groups, not this bit table):

- "DFT - All" is an 8:1 mux of pairs; `b2..b0` select which "dft per ADC" pair reaches
  `dft0_buff`/`dft1_buff`: `a`=dft13/dft03, `a1`→ wait, schematic inputs per brief: a=dft13,
  a1=dft03; b=dft12/dft02; c=dft11/dft01; d=dft10/dft00; e=dft17/dft07; f=dft16/dft06;
  g=dft15/dft05; h=dft14/dft04.
- Inside each "dft per ADC" mux, `s0..s3_dft` choose among `d0..d7` = `phirst, phi1, phi2,
  vtc_out_dft` (repeated on `d4..d7`).
- **UNCONFIRMED**: bit order, which letter maps to which `b2..b0` code, which `s` code
  gives which signal on `dft_0` vs `dft_1`, and (§2.2) how many select bits actually exist.
  The config/wizard will expose this as "pick ADC k, signal X" per the brief, computing raw
  bits from a lookup table marked UNCONFIRMED until Dima answers — raw bit control stays
  available as a fallback.

## 5. Open questions (Dima)

From the session1 explainer (§7 there) plus the task brief's own list (§4), merged and
de-duplicated:

1. **Q1 — slice 0 reachability.** In `sipo_wrapper.sv`, the reset branch loads `sel[23:8]
   <= parallel_out[23:8]`, but `parallel_out` resets to zero on the same `rst_n`, so slice 0
   loads zeros; the first `phi_R` then jumps straight to bits `[39:24]`. Bug, or is slice 0
   intentionally meant to land at `[39:24]`?
   **Correction (2026-10-22, `phase6_sipo_piso_tb`, docs/issues.md):** "loads zeros" only
   holds for the first load. Both resets are nonblocking, so the reset branch copies
   `parallel_out` as it was *before* the reset: `sel[23:8]` starts at the **previous** load's
   slice 0. The current frame's slice 0 still never reaches `sel`. Also ask: an async reset
   that loads data, not a constant, isn't a normal reset flop; how was this synthesized?
2. **Q2 — index never wraps.** `index` in `sipo_wrapper.sv` runs 24→40→...→136 and is never
   reset; after the 7th `phi_R` it reads `[135:120]` (OK), the 8th would read `[151:136]`,
   past `WIDTH=136` (undefined). How many `phi_R` cycles happen per inference, and must
   `rst_sipo` + the full 136-bit frame be reloaded every time?
3. **Q3 — bit/slice order.** Is slice 0 the input MSB or LSB? Which `sel` bit is which row?
   What do the 8 bits of `sel[7:0]` select exactly?
4. **Q4 — phases.** The pad list has `clk` but no `phi_1/phi_2/phi_R` pins, and `CLK GEN` is
   on-chip (confirmed again by the `Interface - Dima` sheet: Clk Gen block has in-ports
   `clk, reset, set` and out-ports `phi1, phi2, phir`). Do we only ever supply `clk` (at what
   frequency?), or must phases be generated on the FPGA after all? CLAUDE.md §7 item 4
   currently says "do not build a non-overlapping-phase generator in the FPGA" — this spec
   does not change that, pending this answer.
5. **Q5 — PISO column mapping.** Which physical column is `out0`/`out1` of which PISO stage?
   The pin sheet says `piso_in<13:0>` while the block diagram says `Dout<14:0>` — 14 or 15
   bits?
6. **Q6 — unknown pins / polarities.** Meaning and polarity of `reset`, `set`, `s0_p..s2_p`,
   `pulse`, and the DFT selects (ties into §4). Are `rst_sipo`/`rst_piso` active-low *at the
   pad*, as in the RTL, or inverted somewhere between pad and core?
7. **Q7 — levels and speed.** Our FMC is fixed at LVCMOS18 (VADJ jumper on 1.8 V, CLAUDE.md
   §4) — does the chip's digital pad actually expect 1.8 V? What is the maximum safe
   `clk_sipo`/`clk_piso` rate?
8. **Q8 — slide-3 wording check.** Weights live in the Y-Flash cells, written by
   program/erase pulses; the SIPO carries inputs and row/column selects, not weights
   themselves. Confirm this reading is correct.
9. **(new, this phase) rst_sipo's true pad number** — 37, 39, or something else (§2.1).
10. **(new, this phase) DFT-per-ADC select width** — 2, 3, or 4 bits (§2.2), and whether
    `PISO_WR` / the stand-alone test structure are still present on the current chip at all
    (§2.6, §2.7).

## 6. Config schema (shape only — formalized in Phase 1)

Adapting the task brief's example directly; Phase 1 will turn this into a real JSON-Schema
/ pydantic model plus the Excel import/export columns.

```yaml
modes:            # ordered list kept in data, so WRITE can later split into PROGRAM/ERASE
  READ: {}
  WRITE: {}
  INFERENCE:
    Clock Generator:
      clk:   {type: CLOCK, freq: 1MHz, duty: 50%}
      reset: {type: PULSE, width: 1us, delay: 0, polarity: active_low}   # polarity TBD, Q6
      set:   {type: LOW}                                                 # TBD, Q6
    Array with Muxes:
      s0_p: {type: LOW}            # TBD meaning, Q6
      s1_p: {type: LOW}
      s2_p: {type: LOW}
      pulse: {type: PULSE, width: 1us, delay: 0}   # TBD meaning/width, Q6/Q7
    DSA:
      rst_dsa: {type: PULSE, width: 100ns, polarity: active_high}        # TBD, Q6
    SIPO:
      rst_sipo: {type: PULSE, width: 100ns, polarity: active_low}         # from RTL
      clk_sipo: {type: CLOCK, freq: 1MHz, cycles: 136, delay: 2us}
      sipo_in:  {type: SERIAL, clock: clk_sipo, data: frame0.hex,
                 msb_first: true, data_edge: falling}
      cs:       {type: PULSE, width: 1us, delay: 140us}
    PISO:
      rst_piso: {type: PULSE, width: 100ns, polarity: active_low}
      clk_piso: {type: CLOCK, freq: 1MHz, cycles: 168, delay: 0}
      shift:    {type: LOW}        # sequenced (Phase 7): 0 for the load edge, then 1
    DFT - All:
      dft_select: {adc: 3, signal: phi1}   # helper -> b0..b2, s0..s3 (UNCONFIRMED, §4)
      # raw alternative: b_dft: {type: BUS, value: 0b011}

pin_limits:        # per-pin safe limits, enforced by the Phase-1 validator
  clk_sipo: {allowed_types: [CLOCK], min_period_ticks: 2, max_freq_hz: TBD}
  cs:       {allowed_types: [PULSE], min_width_ticks: 1, idle_level: LOW}
  # ... one entry per of the 26 signals in §3; most limits are TBD pending §5

pin_map:            # chip signal -> FMC LA_P pin; Phase 1/4 decision, TBD for all 26 now
  clk_sipo: TBD
  # ...
```

## 7. FPGA register map (draft — superseded by Phase 5)

**Superseded by Phase 5**: the real, concrete, byte-level register map is
`docs/link_register_map.md` (implemented in `fpga/src/link_ctrl.sv`, not this sketch). It
only covers Phase 5's 5 fixed debug cells (`test_clock`/`test_pulse`/`test_serial`/
`test_low`/`test_high`, the same pairs Phase 4 used), not the full 22+4-cell generic
layout sketched below — that part of this draft is still open, carried forward to
whichever phase wires the real per-pin generic config to the link. The sketch below is
kept for history.

All parameters stored as **100 MHz-tick integers** (10 ns/tick) per the architecture rules.
Address space sketch, byte-addressed, 32-bit words:

| Region | Address range | Contents |
|---|---|---|
| Global control | `0x0000-0x000F` | `MODE_SELECT` (rd/wr), `APPLY` (self-clearing strobe), `RUN`/`STOP` (rd/wr), `STATUS` (ro: busy, fault bits), `TIMEBASE_ID` (ro, fixed 100 MHz) |
| Shadow regs, 22 input cells | `0x0100-0x02FF` | 8 bytes/cell × 22 = 176 B: `CTRL` (type[2:0], polarity, enable), `PARAM0` (period/width ticks, 16b), `PARAM1` (duty/delay ticks, 16b), `PARAM2` (cycles/repeat, 16b) |
| Active regs, 22 input cells | `0x0300-0x04FF` | mirrors shadow layout; written only by the `APPLY` strobe, atomically, on one clock |
| Capture/status regs, 4 output cells | `0x0500-0x05FF` | per cell: last captured value/width, edge count, fault/timeout flag |
| DFT helper lookup | `0x0600-0x06FF` | raw `b0-2_dft`/`s0-3_dft` bit patterns per (ADC, signal) selection — UNCONFIRMED table, §4 |

This is a sketch for sizing only; the real map is generated by the Phase 4 Python tool
(`nemo_cfg_pkg.sv` + a matching address header) once cell count and parameter widths are
fixed in Phase 1/3.

## 8. Link protocol draft (framed) — superseded by Phase 5

**Superseded by Phase 5**: this framing was implemented essentially as drafted (same
`SOF`/`CMD`/`ADDR`/`LEN`/`DATA`/`CHECKSUM` shape), with two differences from the sketch
below worth noting: (1) `LOAD_MODE` is explicitly unimplemented — it's wired straight to
a NACK response, not silently ignored, so a caller can tell; (2) `DATA` is **not** absent
for `READ_REG`/`READ_CAPTURE` requests — the request frame still carries `LEN` dummy
payload bytes (the parser doesn't special-case `CMD` when deciding whether to expect a
data phase), even though their content is ignored. See `docs/link_register_map.md` for
the final, concrete version and `fpga/src/link_ctrl.sv`/`tools/nemo_ctl/link.py` for the
two sides that actually speak it. The sketch below is kept for history.

Simple fixed-header frame, PC → FPGA and FPGA → PC symmetric:

| Field | Size | Notes |
|---|---|---|
| `SOF` | 1 B | `0xAA`, frame sync |
| `CMD` | 1 B | `WRITE_REG=0x01, READ_REG=0x02, LOAD_MODE=0x03, APPLY=0x04, RUN=0x05, STOP=0x06, STATUS=0x07, READ_CAPTURE=0x08` |
| `ADDR` | 2 B | register address from §7 |
| `LEN` | 1 B | payload length in bytes, 0-252 |
| `DATA` | `LEN` B | payload (absent for `APPLY/RUN/STOP/STATUS`) |
| `CHECKSUM` | 1 B | XOR of `CMD..DATA` |

Test order per the brief: echo → register write/readback → full config. **This framing is
only needed if the link is a raw byte stream (option a or c in §9).** If option (b),
Zynq PS + AXI-Lite, is chosen instead, there is no byte-stream framing at all — `WRITE_REG`/
`READ_REG` become direct AXI-Lite reads/writes to the same address map, and this table is
moot. Finalizing this section is blocked on the link decision (§9).

## 9. Link options

| Option | Pros | Cons | Fits current toolchain? |
|---|---|---|---|
| (a) USB-UART adapter on a PMOD, pure RTL | No block design, no Vitis — stays inside the "RTL project, no block design" rule already set for this project (CLAUDE.md §4). Framing in §8 applies directly. Simple UART core is a well-understood, synthesizable, testable block. | Need a separate USB-UART bridge chip/cable on a PMOD; PMOD bank voltage is **not in any repo file** — ZedBoard PMODs are commonly documented (Digilent reference manual) as 3.3 V LVCMOS33, but that number is **not confirmed against our own board/manual copy** and must not be assumed. **TBD: confirm PMOD bank voltage before wiring anything.** | **Yes**, if the PMOD voltage checks out. |
| (b) Zynq PS + AXI-Lite (on-board USB-UART, wired to the PS) | No extra cable — reuses the ZedBoard's built-in USB-UART; AXI-Lite gives a clean register-mapped interface, no §8 framing needed. | Requires a block design + Vitis. **This directly conflicts with CLAUDE.md §4: "Vivado 2022.1 (RTL project, part xc7z020clg484-1, no block design)."** Adopting it means either changing that project rule or keeping the PS path as a separate sub-project. | **No**, not without changing an existing project rule — flagged, not decided here. |
| (c) Vivado VIO over JTAG | Zero extra hardware, fastest to stand up, good for Phase 3/4 bring-up and debug. | Explicitly debug-only — requires a PC tethered via JTAG/Vivado hardware manager, not a standalone link; doesn't give the "change a setting from the PC without re-synthesis" Phase 5 exit criterion on its own (VIO probes are fixed at synthesis time unless re-generated). | Usable now, not as the final link. |

**Decision (2026-10-13, approved by Rahaf): option (a), USB-UART on a PMOD.** Still
contingent on confirming the PMOD bank voltage against the actual ZedBoard reference manual
before wiring anything — that check has not been done yet and is carried forward as an open
item for Phase 4/5 hardware bring-up. (c), VIO over JTAG, remains available in parallel for
Phase 3/4 debug regardless, since CLAUDE.md already lists Vivado ILA as a planned
verification tool. §8's framed protocol is now the one that applies (no AXI-Lite path).

**PMOD / UART facts confirmed 2026-10-22** (Avnet *ZedBoard Zynq Evaluation and Development
Hardware User's Guide*, **Version 1.1, 1 Aug 2012**, an early revision; recheck against
the guide or schematic for our board revision before wiring):
- The four PL Pmods JA1–JD1 connect to **PL Bank 13 at 3.3 V** (§2.9.2; Table 21 "Zynq Bank
  Voltage Assignments": Bank 13 3.3V). So option (a) uses **LVCMOS33**, not the FMC's
  LVCMOS18, and the adapter must be a **3.3 V** logic-level USB-UART.
- JA pins (Table 16): JA1 **Y11**, JA2 **AA11**, JA4 AA9, JA7 AB11, JA8 AB10, JA9 AB9, JA10 AA8.
  JA3 reads "Y19" in this revision's table, which community XDCs give as Y10; JA3 is not
  needed for the UART. Which of JA1/JA2 is the FPGA's RX vs TX depends on the adapter's own
  pinout (e.g. Digilent PmodUSBUART vs a bare FTDI TTL cable), so it stays open until the
  adapter is chosen.
- The onboard USB-UART (CY7C64225, micro-USB **J14**) is wired to the **PS**: Zynq pins D11 /
  C14 in **MIO Bank 1/501 (1.8 V)** (Table 6). PL logic can't reach it without software on
  the ARM forwarding the bytes. That is option (b) above (block design + Vitis), not
  something an XDC change can do.
- FMC banks 34/35 are on VADJ, set by jumper **J18**. Default 2.5 V; the 3.3 V position is
  deliberately unpopulated (Table 21 note). Our designs need **1V8** (CLAUDE.md §4).
- 2026-10-22: the team reports owning only the boxed accessories (12 V adapter, micro-USB
  cables), **no PMOD USB-UART adapter**. So option (a) still needs an adapter before
  EXP-02 / EXP-04 can run.

## 10. Resource estimate

**Superseded by Phase 3** (`fpga/src/sig_cell.sv`, `cap_cell.sv`, `run_ctrl.sv` now exist
and pass self-checking testbenches — see `docs/WORKLOG.md`'s Phase 3 entry). The original
hand-counted guess below is kept for history; §10a has a real synthesized number instead.

~~26 generic cells (22 `sig_cell` + 4 `cap_cell`) + one `run_ctrl` + register file + link
interface. Order-of-magnitude only, each `sig_cell`/`cap_cell` sized like a 16-bit counter +
16-bit comparator + double-buffered (shadow/active) control word:~~

| Block | Rough FF | Rough LUT |
|---|---|---|
| 22 × `sig_cell` | ~70-90 each → ~1800 | ~40-60 each → ~1100 |
| 4 × `cap_cell` | ~70-90 each → ~320 | ~40-60 each → ~200 |
| `run_ctrl` + register file + link interface | ~300-500 | ~300-500 |
| **Total (estimate)** | **~2500-2700** | **~1600-1800** |

### 10a. Phase 3: real synthesized number (yosys, not Vivado)

No Vivado license/server in this environment, so `fpga/tb/utilization_estimate_top.sv`
(26 cells unrolled explicitly, `TICK_W=20`, `SERIAL_W`/`CAP_W` sized to the real frame
widths — 136 for `sipo_in`, 168 for `piso_out`, 1 for every pin that never uses
SERIAL/serial-capture) was run through **yosys 0.69, `synth_xilinx -family xc7`** instead —
a real generic-xc7 synthesis, not a hand count, though still not a true Vivado
place-and-route (no timing closure, no routing congestion check):

| Resource | Count | Of XC7Z020 | % |
|---|---|---|---|
| FF (`FDCE`+`FDPE`) | 4,923 | 106,400 | 4.6% |
| LUT (`LUT2`-`LUT6`) | 6,449 | 53,200 | 12.1% |
| `CARRY4` chains | 1,254 | 13,300 slices | — (carry logic for the wide tick-counter comparisons) |
| yosys "Estimated LCs" | 5,244 | 53,200 | 9.9% |

**[measured — real synthesis output, not estimated]**, reproducible with:
```
yosys -p "read_verilog -sv fpga/src/sig_cell.sv fpga/src/cap_cell.sv fpga/src/run_ctrl.sv \
           fpga/tb/utilization_estimate_top.sv; \
           synth_xilinx -family xc7 -top utilization_estimate_top; stat"
```
LUT usage (12.1%) is higher than the original hand-counted guess (~3%) mainly because of
the two wide shift registers (136+168=304 bits total) and the `CARRY4`-chain comparators
every tick-counter needs at `TICK_W=20` — still comfortably inside the chip's budget, but
a real number instead of a guess. Not yet a Vivado report; that's a Phase 4 to-do once a
real top level with the actual register file exists.

## 11. Exit criteria for this phase

Per the task brief: approve this spec, and choose the link (§9). **Both done 2026-10-13** —
spec approved, link = option (a) USB-UART on a PMOD (pending PMOD voltage confirmation,
carried into later phases). Phase 1 starts next.
