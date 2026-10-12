# Pin verification status

Pair i = output `LAi_P` (J3 pos. i, P column) -> input `LA(i+16)_P` (J3 pos. 16 for i=0, otherwise J2 pos. i+16, P column).
Package pins are from `fpga/constraints/*.xdc` (all files agree).

Legend: PASS / FAIL / – (not tested). All results here are **[measured on board]** unless marked otherwise.

| Pair | Out (LA / pkg pin / header) | In (LA / pkg pin / header) | Static 0/1 (T2) | 1 MHz checker (T3) | ~100 Hz multimeter (T4) | Scope |
|---|---|---|---|---|---|---|
| 0  | LA00_P / M19 / J3-0  | LA16_P / J20 / J3-16 | PASS | PASS | PASS (0.899 V, ideal 0.9 V) | – |
| 1  | LA01_P / N19 / J3-1  | LA17_P / B19 / J2-17 | – | – | – | – |
| 2  | LA02_P / P17 / J3-2  | LA18_P / D20 / J2-18 | – | – | – | – |
| 3  | LA03_P / N22 / J3-3  | LA19_P / G15 / J2-19 | – | – | – | – |
| 4  | LA04_P / M21 / J3-4  | LA20_P / G20 / J2-20 | – | – | – | – |
| 5  | LA05_P / J18 / J3-5  | LA21_P / E19 / J2-21 | – | – | – | – |
| 6  | LA06_P / L21 / J3-6  | LA22_P / G19 / J2-22 | – | – | – | – |
| 7  | LA07_P / T16 / J3-7  | LA23_P / E15 / J2-23 | – | – | – | – |
| 8  | LA08_P / J21 / J3-8  | LA24_P / A18 / J2-24 | – | – | – | – |
| 9  | LA09_P / R20 / J3-9  | LA25_P / D22 / J2-25 | – | – | – | – |
| 10 | LA10_P / R19 / J3-10 | LA26_P / F18 / J2-26 | – | – | – | – |
| 11 | LA11_P / N17 / J3-11 | LA27_P / E21 / J2-27 | – | – | – | – |
| 12 | LA12_P / P20 / J3-12 | LA28_P / A16 / J2-28 | – | – | – | – |
| 13 | LA13_P / L17 / J3-13 | LA29_P / C17 / J2-29 | – | – | – | – |
| 14 | LA14_P / K19 / J3-14 | LA30_P / C15 / J2-30 | – | – | – | – |
| 15 | LA15_P / J16 / J3-15 | LA31_P / B16 / J2-31 | – | – | – | – |

Designs: T2 = `fmc_selectable_loopback`, T3 = `fmc_clock_loopback`, T4 = `fmc_clock_loopback_slow`.
