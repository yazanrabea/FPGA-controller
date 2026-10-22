# EXP-05: JTAG link feasibility (step J1): bytes over the J17 PROG cable

Step J1 of the JTAG PC-link plan (`docs/decisions.md`, "PC link for EXP-02 / EXP-04: JTAG
over J17"). Question: can the PC move data to and from FPGA logic through the cable that
already programs the board, reliably and fast enough to replace the missing USB-UART
adapter? Run 2026-10-22 on the Windows lab PC, Yazan at the board.

## 1. Setup

- **Design**: `fpga/src/jtag_echo_top.sv` + `fpga/src/jtag_echo_core.sv`,
  `fpga/constraints/jtag_echo_top.xdc` (only `clk` and LD0-LD7, lines copied from the
  verified `phase4_loopback_top.xdc`; no FMC pin driven).
  - A `BSCANE2` user data register, 1024 bits (128 bytes per scan).
  - Each scan returns the **bitwise inverse of the previous scan's data**: both directions
    work and the data went through FPGA logic.
  - LD0-LD7 = bits [7:0] of the last scan, through a 2-FF synchronizer.
  - Final version on **USER4** (IR `0x23`); the first build used USER1 (§4).
- **PC side**: `scripts/jtag_echo_test.tcl`, run with xsdb from Vivado
  (`C:\Xilinx\Vivado\2022.1\bin\xsdb.bat scripts/jtag_echo_test.tcl C1 2000`). It uses
  `jtag sequence` on the `xc7z020` target; xsdb keeps `arm_dap` in bypass.
- **Board**: ZedBoard, PROG micro-USB on J17, J18 on 1V8. The EXP-01 jumpers stayed in;
  harmless, the design drives no FMC pin.
- **Simulation**: `fpga/tb/jtag_echo_core_tb.sv` (`scripts/run_jtag_sim.sh`), models the
  TAP's Capture/Shift/Update sequence. 9/9 [simulated, xsim 2022.1].
- **Vivado** (report, not a measurement): timing met for both clocks, `sys_clk_pin`
  100 MHz and `jtag_tck` constrained at 30 MHz (USER4 build: WNS +31.15 ns on TCK, +9.24 ns on sys clk);
  1025 LUTs, 2064 FFs, 9 IOBs.

## 2. JTAG chain as xsdb sees it [measured on board]

```
1  Digilent Zed 210248B4A8BD
   2  arm_dap (idcode 4ba00477 irlen 4)
   3  xc7z020 (idcode 23727093 irlen 6 fpga)
```
JTAG frequency: 15 MHz (hw_server default for this cable).

## 3. Results, final design (USER4) [measured on board]

| Check | Result | Pass |
|---|---|---|
| First scan after programming | all `F` (= ~0, the FFs' power-up value) | PASS |
| Scans 2-4 return ~(previous scan's data) | yes | PASS |
| 2000 consecutive scans, each a separate `run`, `jtag lock` held | 2000/2000 correct | PASS |
| 500 scans **without** `jtag lock` | 0/500 bad | PASS |
| Value persists 60 s unlocked, and across disconnect + reconnect | `C1C1...` read back both times | PASS |
| LEDs after writing pattern `C1` | LD7, LD6, LD0 on (= `1100 0001` = 0xC1), steady | PASS |
| Speed, one scan per `run` (how a polling link would use it) | 1.3 ms/scan, **≈98 kB/s** | — |
| Speed, 2000 scans batched in one `run` | **≈1.0 MB/s** | — |

For comparison, the planned UART at 115200 baud gives ≈11.5 kB/s.

Bit order (needed for J4, the Python transport):
- **xsdb `-hex` strings are byte-little-endian**: the first two hex digits are bits [7:0],
  the last two the top byte. Each pair is in normal order (no bit reversal: `C1` showed as
  0xC1 on the LEDs).
- **Always scan exactly DR_BITS bits.** `arm_dap` sits between the cable's TDI and the
  FPGA, so the first bit clocked into our register is the DAP's bypass bit, and xsdb adds
  one clock to compensate. In a full-length scan that bit falls out the far end. In a
  short scan it stays: an 8-bit scan of `C1` stored `C1` + one `0` bit below it
  (string end `...7FC1`).

## 4. Problem found: hw_server scans USER1 on its own

First build on **USER1** (IR `0x02`), all [measured on board]:
- The echo check passed, but **12 of 500** scans read back all `F` (15 MHz, no lock).
- 5 MHz, no lock: **14/500**, so it's not signal integrity.
- With `jtag lock`: **0/500**, and faster (1.28 vs 1.56 ms/scan).
- In the failing scans the *write* still landed (the next scan echoed it correctly); only
  the read-back was wrong.
- Every new xsdb session found the stored value **cleared to 0**.
- While the session was held open unlocked for 90 s, **all 8 LEDs blinked** (Yazan), even
  though our design can only show one fixed byte.

Explanation: hw_server scans the USER registers itself (debug-core discovery; Vivado's
debug hub uses USER1 by default) and writes into our register. Moving to **USER4** removed
all three symptoms (§3). The exact hw_server behaviour is inferred from these symptoms, not
from documentation. Details in `docs/issues.md`.

Consequence for the real bridge (J2): it must **ignore any scan that doesn't carry a valid
header** (magic + length + valid bits), so a stray scan from any tool can never inject
bytes into `link_frame`. The transport also keeps `jtag lock` while it talks.

## 5. Conclusion

**PASS, 2026-10-22: the JTAG link is feasible.**
- Data moves both ways through FPGA logic over the existing J17 cable.
- With USER4 there were no errors in 2500+ scans.
- ≈98 kB/s polling, ≈1 MB/s batched: 8-85× the planned UART.
- No new pins, adapter or voltage decision.

Next: J2, the bridge RTL (`jtag_link_bridge.sv`). It needs a framed, validated DR word, a
TCK -> 100 MHz byte FIFO and a reverse one, always full-length scans, on USER4.
