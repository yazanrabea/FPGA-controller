# Pin verification status

Pair i = output `LAi_P` (J3 pos. i, P column) -> input `LA(i+16)_P` (J3 pos. 16 for i=0, otherwise J2 pos. i+16, P column).
Package pins are from `fpga/constraints/*.xdc` (all files agree).

Legend: PASS / FAIL / – (not tested). All results here are **[measured on board]** unless marked otherwise.

| Pair | Out (LA / pkg pin / header) | In (LA / pkg pin / header) | Static 0/1 (T2) | 1 MHz checker (T3) | ~100 Hz multimeter (T4) | Scope | EXP-01 generic controller |
|---|---|---|---|---|---|---|---|
| 0  | LA00_P / M19 / J3-0  | LA16_P / J20 / J3-16 | PASS | PASS | PASS (0.899 V, ideal 0.9 V) | PASS timing (1 MHz, 10 MHz, 100 kHz 25 %); overshoot +0.4 / -0.4 V at J3-0, +0.62 / -0.7 V at J3-16 (EXP-06) | PASS (CLOCK, 0.9 V) |
| 1  | LA01_P / N19 / J3-1  | LA17_P / B19 / J2-17 | – | – | – | PASS (pulse 1 µs / 10 µs; digital channel, EXP-06) | PASS (PULSE) |
| 2  | LA02_P / P17 / J3-2  | LA18_P / D20 / J2-18 | – | – | – | PASS (static 0 on a digital channel, EXP-06) | PASS (SERIAL 0xA5) |
| 3  | LA03_P / N22 / J3-3  | LA19_P / G15 / J2-19 | – | – | – | PASS (static 0 on a digital channel, EXP-06) | PASS (LOW, 0 V) |
| 4  | LA04_P / M21 / J3-4  | LA20_P / G20 / J2-20 | – | – | – | PASS (static 1 on a digital channel, EXP-06) | PASS (HIGH, 1.8 V) |
| 5  | LA05_P / J18 / J3-5  | LA21_P / E19 / J2-21 | – | – | – | – | – |
| 6  | LA06_P / L21 / J3-6  | LA22_P / G19 / J2-22 | – | – | – | – | – |
| 7  | LA07_P / T16 / J3-7  | LA23_P / E15 / J2-23 | – | – | – | – | – |
| 8  | LA08_P / J21 / J3-8  | LA24_P / A18 / J2-24 | – | – | – | – | – |
| 9  | LA09_P / R20 / J3-9  | LA25_P / D22 / J2-25 | – | – | – | – | – |
| 10 | LA10_P / R19 / J3-10 | LA26_P / F18 / J2-26 | – | – | – | – | – |
| 11 | LA11_P / N17 / J3-11 | LA27_P / E21 / J2-27 | – | – | – | – | – |
| 12 | LA12_P / P20 / J3-12 | LA28_P / A16 / J2-28 | – | – | – | – | – |
| 13 | LA13_P / L17 / J3-13 | LA29_P / C17 / J2-29 | – | – | – | – | – |
| 14 | LA14_P / K19 / J3-14 | LA30_P / C15 / J2-30 | – | – | – | – | – |
| 15 | LA15_P / J16 / J3-15 | LA31_P / B16 / J2-31 | – | – | – | – | – |

Designs: T2 = `fmc_selectable_loopback`, T3 = `fmc_clock_loopback`, T4 = `fmc_clock_loopback_slow`.

EXP-01 column: `docs/experiments/EXP-01_phase4_generic_controller_bringup.md`, run 2026-10-22
[measured on board] with `phase4_loopback_top` (generic `sig_cell`/`cap_cell`, not the T1-T4
designs): each pair carried one signal type, checked with the LEDs + internal checker, and
pairs 0/3/4 also with the Fluke 115. This is the first signal on pairs 1-4. The T2-T4 columns
stay "–" for pairs 1-4 because those designs were not run on them.

Scope column: `docs/experiments/EXP-06_scope_timing.md`, 2026-10-26 [measured on board] (Keysight CX3324A analog, Agilent MSO-X 2002A digital channels), driven by `phase5_link_jtag_top`. Signal quality (ringing) is an open issue in `docs/issues.md`.

**Pairs 5-15: not verified.** On 2026-10-26 Rahaf decided to skip their verification for now
and assume they work, because no current experiment uses them. Nothing has been measured on
them; the "–" above means *not tested*, not *passed*. Verify a pair (e.g. with
`fmc_selectable_loopback` / `fmc_clock_loopback_slow`, which select pairs 0-15 with
`sw[3:0]`) before the chip uses that pin.
