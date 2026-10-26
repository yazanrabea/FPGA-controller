# Work log

Chronological, one entry per session. Format: see CLAUDE.md section 9.
Tag every result **[simulated]** or **[measured on board]**.

## Currently working on
| Person | Task | Branch | Files touched |
|---|---|---|---|
| Rahaf | Review Phases 6-7 on `main` (done by Yazan). EXP-01 was run by Yazan 2026-10-22. | — | — |
| Yazan | Signals (waveform) panel in the browser editor | `feature/yazan-gui-waves` | `tools/nemo_ctl/{waves.py,gui.py,data/config_gui.html}`, `tools/nemo_ctl/tests/test_waves.py`, `docs/{USER_MANUAL,WORKLOG}.md`, `tools/nemo_ctl/README.md` |

---

## 2026-10-22 (lab PC, board), J5 part 2: EXP-04 over JTAG, Yazan at the ZedBoard + Claude, branch main
- Goal: Phase 7 round 2's hardware exit criterion: a step sequence loaded and run from the PC.
- Done:
  - Programmed `phase7_link_jtag_top`; ran EXP-04 §4 runs 1-5 with `--jtag`. Run 3 (abort)
    and Run 5 (program-verify) were run from one Python session each (`open_jtag(link_cls=SeqLink)`):
    each CLI command restarts xsdb, too slow to hit step 2.
  - No code changed. Docs: EXP-04 §5/§6, CLAUDE.md §5/§7, decisions (J1-J5 done), HANDOFF.
- Hardware setup: unchanged (J18 1V8, the 5 jumpers, J17); J2-20 pulled for Run 2 only and
  put back. Fluke 115 DC V.
- Results **[measured on board]** (table in EXP-04 §5):
  - status idle; load 6 steps (2.7 s); step 0 levels correct, LEDs off.
  - Run 1: `done late`, last step 5, LD0/LD2/LD4/LD6, data_in 0xA5.
  - Run 2: `fault`, last step 4, exit 1, LD2 + LD5.
  - Run 3: abort at 2.81 s, `aborted`, last step 2, LD1, J3-0 0 V.
  - Run 4: data 0x3C copy, data_in 0x3C, no re-synthesis.
  - Run 5: program_verify passed after 4 iterations (0x11, 0x22, 0x33, 0x44).
- Problems / fixes: none.
- Decisions: none.
- Next steps: the JTAG plan is complete. Remaining project items: scope/ILA timing
  measurements, LA pairs 5-15, Dima's questions -> chip-pin map -> Phase 8.

---

## 2026-10-22 (lab PC, board), J5 part 1: EXP-02 over JTAG, Yazan at the ZedBoard + Claude, branch main
- Goal: Phase 5's exit criterion on the board over the JTAG link: change a clock from the PC
  with no re-synthesis and see it on the multimeter.
- Done:
  - Programmed `phase5_link_jtag_top`; ran EXP-02 §3 steps 5-9 with `--jtag` (steps 1/4,
    UART adapter, don't apply).
  - Fixed the CLI frequency display (`_fmt_hz`, `tools/nemo_ctl/cli.py`, + test).
  - Docs: EXP-02 §4/§5, `docs/issues.md`, CLAUDE.md §5, HANDOFF.
- Hardware setup: J18 1V8, EXP-01 jumpers, switches down, J17. Fluke 115 DC V, ground on an
  SMA shell.
- Results **[measured on board]** (table in EXP-02 §4):
  - `link status`: STOPPED.
  - Readback after set-clock 100 Hz: PARAM_A 1,000,000 / PARAM_B 500,000.
  - APPLY + RUN: RUNNING, LD4 on, **J3-0 0.9 V**.
  - **Live, no STOP**: duty 25% -> **0.45 V**; then 1 Hz -> LD0/LD1 blink 1/s; LD4 on throughout.
  - STOP: LD4 off, J3-0 0 V. LD5 (link error) off.
  - **[not hardware]** pytest 213 passed, 1 skipped.
- Problems / fixes: the `0.0000 MHz` display (cosmetic, fixed).
- Decisions: none.
- Next steps: J5 part 2, EXP-04: `phase7_link_jtag_top`, a sequence loaded and run from the
  PC (`cli seq ... --jtag`).

---

## 2026-10-22 (lab PC), JTAG link J4: Python transport, Yazan + Claude, branch main
- Goal: step J4 (Yazan: "continue"): the PC side of the JTAG link, so `Link` / `SeqLink` /
  the CLI work over J17.
- Done:
  - `tools/nemo_ctl/jtag.py`: scan format, `JtagTransport` (the transport rules), `XsdbScanPort`,
    `open_jtag()`.
  - `scripts/jtag_server.tcl`: runs inside xsdb, holds `jtag lock`, serves `S <hex>` scans on
    127.0.0.1 (OS-chosen port, announced as `READY <port>`).
  - `tools/nemo_ctl/cli.py`: `--jtag` as the alternative to `--port` for `link ...` and
    `seq ...`.
  - Tests: `tools/nemo_ctl/tests/test_jtag.py` (16; a Python model of the bridge in front of
    the existing Phase 5 / Phase 7 frame fakes) + 2 in `test_cli.py`.
  - Docs: USER_MANUAL §6.4, `tools/nemo_ctl/README.md`.
- Hardware setup: board still running `jtag_echo_top` (USER4) from J1, J17 connected.
- Results:
  - **[not hardware]** pytest: 212 passed, 1 skipped (194 + 16 + 2).
  - **[measured on board]** `XsdbScanPort` against `jtag_echo_top`: server up in 6.0 s;
    scan 2 = ~scan 1; 200 scans through Python + socket + xsdb all echoed, **1.18 ms/scan,
    ~109 kB/s**. (The echo check doesn't prove byte 0's position; J5 will, via the `jl` magic.)
- Problems / fixes: one test expectation was wrong. `write()` returns when the bridge has
  accepted the bytes, so the test now does a `status()` round trip before checking the
  registers.
- Decisions: Python talks to xsdb over a local TCP socket served by a Tcl script inside xsdb,
  rather than driving an interactive xsdb prompt (whose output buffering is unreliable).
- Next steps: J5 on the board: program `phase5_link_jtag_top`, run EXP-02 over JTAG (change
  a clock from the PC, see it on the multimeter), then `phase7_link_jtag_top` + EXP-04.
  After Yazan's OK.

---

## 2026-10-22 (lab PC), JTAG link J3: link tops over JTAG, Yazan + Claude, branch main
- Goal: step J3 (approved by Yazan): the Phase 5 and Phase 7 link tops on the JTAG transport,
  and their first bitstreams.
- Done:
  - `fpga/src/phase5_link_top.sv`, `fpga/src/phase7_link_top.sv`: new parameter
    `LINK = "UART"` (default, unchanged) or `"JTAG"`, where `jtag_link_bscan` replaces
    `uart_rx`/`uart_tx`. The bridge's overflow flag takes the UART framing error's place
    (P5 LD5 / P7 LD7 = link error).
  - New tops `fpga/src/phase5_link_jtag_top.sv`, `phase7_link_jtag_top.sv`: the existing top
    with `LINK("JTAG")` and no `rxd`/`txd` ports (an unconstrained top-level port stops the
    bitstream).
  - New XDCs `fpga/constraints/phase5_link_jtag_top.xdc`, `phase7_link_jtag_top.xdc`: every
    constraint line of the existing link-top XDC unchanged (checked with `diff`: identical,
    no rxd/txd lines existed) + the `jtag_tck` clock and the async clock groups.
  - `fpga/tb/bscane2_sim_stub.sv`: simulation-only BSCANE2 stand-in, driven by a
    `jtag_tap_model` instance it finds by name.
  - `fpga/tb/jtag_link_e2e_tb.sv` (both JTAG tops, unmodified, real link frames), added to
    `scripts/run_jtag_sim.sh`.
  - `fpga/src/seq_engine.sv`: `step_cnt1` register for COND_AFTER (timing fix, below).
- Hardware setup: none (no board step in J3).
- Results:
  - **[simulated, xsim]** `jtag_link_e2e_tb` 11/11:
    - P5: STATUS; SCRATCH write/read; clock cell configured over the link, APPLY + RUN;
      LA00 period 20 ticks, then **40 ticks after a live APPLY** (Phase 5's exit criterion,
      over JTAG); bad checksum -> NACK; STOP. Stray scans in between.
    - P7: STATUS; SCRATCH; N_STEPS write/read.
  - **[simulated, xsim]** unchanged after the edits: Phase 5 UART 12/22/7, Phase 7
    40/10/27/21, `jtag_echo_core_tb` 9, `jtag_link_bridge_tb` 19.
  - **[Vivado reports, not measurements]**, first bitstreams of the link tops:

    | Top | sys clk WNS | TCK WNS | LUT / FF / BRAM / IOB |
    |---|---|---|---|
    | `phase5_link_jtag_top` | +0.206 ns | +22.7 ns | 6924 / 11179 / 0.5 / 22 |
    | `phase7_link_jtag_top`, first build | **-0.037 ns** (2 endpoints) | +22.0 ns | 6015 / 10550 / 2.5 / 19 |
    | `phase7_link_jtag_top`, after the `seq_engine` fix | +0.427 ns | +20.3 ns | 6026 / 10582 / 2.5 / 19 |
    | `phase7_seq_loopback_top` (EXP-03 design), rebuilt with the fix | +0.100 ns (was +0.248) | — | — |
- Problems / fixes: the Phase 7 timing miss (`docs/issues.md`).
- Decisions: thin wrapper tops instead of making `rxd`/`txd` conditional: the original tops
  and their UART testbenches stay exactly as they were.
- Next steps: J4 (Python `JtagTransport` through xsdb, `--jtag` for `cli link` / `cli seq`),
  then J5 on the board (EXP-02 / EXP-04 over JTAG). After Yazan's OK.

---

## 2026-10-22 (lab PC), JTAG link J2: bridge RTL, Yazan + Claude, branch main
- Goal: step J2 (approved by Yazan): the RTL that carries link bytes over USER4 scans and
  gives `link_frame` the same ports as the UART.
- Done:
  - `fpga/src/jtag_link_bridge.sv`:
    - TCK-domain scan register;
    - accept-only-if-ready-at-Capture + magic check;
    - handshake CDC (h_tog / p_tog);
    - 256-byte down / up FIFOs, down bytes paced one per 32 clk;
    - the reply builder.
  - `fpga/src/jtag_link_bscan.sv`: BSCANE2 (USER4) + bridge, for the tops (J3).
  - `fpga/tb/jtag_link_bridge_tb.sv`: 19 checks, in `scripts/run_jtag_sim.sh`.
  - Scan format + PC rules: new section "Transport: JTAG over J17" in
    `docs/link_register_map.md`.
- Hardware setup: none (no board step in J2).
- Results:
  - **[simulated, xsim 2022.1]** `jtag_link_bridge_tb` 19/19:
    - 600 bytes round trip, with stray scans (0s, 1s, random, fake magic with a bad length)
      that changed nothing;
    - back-to-back scans: 3 rejected (ready=0), still no loss;
    - SEL low ignored;
    - honouring `free` filled the FIFO exactly; ignoring it set the overflow flag.
  - `jtag_echo_core_tb` 9/9 (unchanged).
  - Mutation check (scratch copies, not committed), both caught by the testbench:
    - accept without the latched ready: the 300-byte back-to-back stream was lost;
    - no magic check: strays injected 152 bytes.
  - **[Vivado report, out-of-context synth + route of `jtag_link_bscan`]** timing met:
    TCK +22.3 ns, 100 MHz +1.21 ns; 2281 LUT, 3134 FF, 48 LUT-RAM.
- Problems / fixes, during development:
  - FIFO memories written inside the async-reset block were built as 4096 FFs, and the
    100 MHz slack was only +0.29 ns. Moved the writes to their own block: 3134 FFs, +1.21 ns.
  - Two testbench expectations were wrong and the RTL was right:
    - the B FIFO took 257 bytes, because its pacer hands one byte out at once;
    - the reply counter already includes test 1's scan.
- Decisions: the protocol needs no ack field: acceptance is the acknowledgement, decided at
  Capture.
- Next steps: J3, a `LINK = UART | JTAG` choice in `phase5_link_top` / `phase7_link_top` +
  XDC, then bitstreams (possible for the first time: JTAG needs no `rxd`/`txd` pins).
  After Yazan's OK.

---

## 2026-10-22 (lab PC, board), JTAG link J1 / EXP-05, Yazan at the ZedBoard + Claude, branch main
- Goal: step J1 of the JTAG PC-link plan (approved by Yazan): prove bytes can move between
  the PC and FPGA logic over the J17 cable, and measure the speed.
- Done:
  - New `fpga/src/jtag_echo_core.sv` (TCK-domain echo register, returns ~previous scan),
    `fpga/src/jtag_echo_top.sv` (BSCANE2, LEDs = last[7:0] via 2-FF sync),
    `fpga/constraints/jtag_echo_top.xdc` (clk + LEDs only, `jtag_tck` 30 MHz, async to the
    sys clock), `fpga/tb/jtag_echo_core_tb.sv`, `scripts/run_jtag_sim.sh`,
    `scripts/jtag_echo_test.tcl` (xsdb: echo check, speed, LED pattern).
  - First build on USER1. Found that hw_server overwrites it, moved to USER4, rebuilt.
  - Docs: `docs/experiments/EXP-05_jtag_link_feasibility.md`, `docs/issues.md`,
    `docs/decisions.md`, CLAUDE.md §6, HANDOFF.
- Hardware setup: unchanged (J18 1V8, EXP-01 jumpers in but unused, J17). xsdb from Vivado
  2022.1 (`C:\Xilinx\Vivado\2022.1\bin\xsdb.bat`), JTAG at 15 MHz.
- Results:
  - **[simulated, xsim]** `jtag_echo_core_tb` 9/9.
  - **[Vivado report]** timing met: TCK +31.15 ns, sys clk +9.24 ns; 1025 LUT / 2064 FF / 9 IOB.
  - **[measured on board]** USER1, no lock: 12/500 bad (15 MHz), 14/500 (5 MHz); with lock
    0/500. USER4: 0/500 without lock, value persists 60 s and across reconnect; 2000/2000
    scans correct; 1.3 ms/scan = ~98 kB/s, batched ~1.0 MB/s. LEDs `C1` = LD7/LD6/LD0 (Yazan).
  - xsdb `-hex` is byte-little-endian (first hex pair = bits [7:0]); `arm_dap`'s bypass bit
    enters first, so scans must be full length.
- Problems / fixes: hw_server writes into USER1 -> USER4 (`docs/issues.md`). Also an xsim
  multi-driver error from `initial` + `always_ff` in `jtag_echo_core.sv` -> declaration
  initializers.
- Decisions: USER4 for the link (`docs/decisions.md`).
- Next steps: J2 (`jtag_link_bridge.sv`: header-validated fixed-length scans, byte FIFOs
  both ways, CDC TCK <-> 100 MHz), after Yazan's OK.

---

## 2026-10-22 (lab PC, board), EXP-03, Yazan at the ZedBoard + Claude, branch main
- Goal: EXP-03, Phase 7's hardware exit criterion, on the EXP-01 wiring.
- Done: programmed `phase7_seq_loopback_top` (built earlier today); ran EXP-03 §4 steps 4-7.
  No code changed. Docs: EXP-03 §5/§6, CLAUDE.md §5/§7, HANDOFF.
- Hardware setup: unchanged from EXP-01 (J18 1V8, the 5 jumpers, J17); switches all down
  before programming. Fluke 115 DC V, ground on an SMA shell.
- Results **[measured on board]** (tables in EXP-03 §5):
  - Before START: J3-1 `rst` 1.8 V, J3-0/2/3/4 0 V, all LEDs off. PASS.
  - Run 1: final LD0/LD2/LD4/LD6 on (step 5, done, 0xA5 captured), LD1/LD3/LD5/LD7 off;
    repeat with the meter on J3-4: 0 -> 1.8 V -> 0 V. PASS.
  - Run 2 (J2-20 end pulled): LD2/LD5/LD6 on = stopped at step 4 with FAULT. PASS.
  - Run 3 (abort in step 2): LD1/LD7 on = step 2, aborted. PASS.
  - Not measured: step durations, clock/pulse widths (scope), the step order during runs.
- Problems / fixes: none. The EXP-01 LD3 transient was not seen (this design has no fault latch on LD3).
- Decisions: none.
- Next steps: the JTAG-link plan (J1-J5) for approval, then EXP-02/EXP-04 over JTAG; scope
  measurements; LA pairs 5-15.

---

## 2026-10-22 (lab PC, board), Yazan at the ZedBoard + Claude, branch main
- Goal: EXP-01, Phase 4 on the board (Phase 4's hardware exit criterion). Yazan also chose
  the PC-link option: JTAG over J17 (`docs/decisions.md`).
- Done:
  - Programmed `phase4_loopback_top` with `scripts/program_board.tcl` and ran EXP-01 §3
    pair by pair, Yazan reading the LEDs and the multimeter, Claude recording.
  - Found and fixed a SERIAL checker bug (LD2 compared 0xA5 with 0x00):
    `fpga/src/phase4_loopback_top.sv`; new `fpga/tb/phase4_serial_tb.sv` (time-scaled,
    jumper in / jumper pulled) run by `scripts/run_phase4_sim.sh`. Rebuilt, reprogrammed,
    pair 2 rerun on the board.
  - Docs: EXP-01 results + conclusion, `docs/pin_verification.md` (new EXP-01 column),
    `docs/issues.md` (the bug + one open LD3 transient), `docs/decisions.md` (JTAG link),
    CLAUDE.md §3/§5/§6/§7.
- Hardware setup: ZedBoard, J18 (VADJ) on **1V8** (confirmed by Yazan before programming,
  and by the 1.8 V reading on J3-4). Jumpers J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19,
  J3-4↔J2-20 (P column). PROG micro-USB on J17. First attempt: no JTAG target and no Digilent
  USB device in Windows at all; Yazan fixed the cable. Fluke 115 on DC V, black probe on the
  outer shell of an SMA jack on the HTG-FMC board.
- Results **[measured on board]** (full tables in EXP-01 §4):
  - RUN off: all pairs LD0=LD1=0, LD3 off, LD2 on except SERIAL (held cleared, expected). PASS.
  - Pair 0 CLOCK 100 Hz: 0.9 V at J3-0 and J3-16; LD0/LD1 blinking on a phone slow-mo video; LD3 off. PASS.
  - Pair 1 PULSE: 5 blinks on LD0 and LD1, LD3 off. PASS (count; width/spacing not timed).
  - Pair 2 SERIAL: first bitstream LD2 never on (checker bug); fixed bitstream LD2 on. PASS after fix.
  - Pair 3 LOW: 0 V at J3-3, LD0=LD1=0, LD2 on. PASS.
  - Pair 4 HIGH: 1.8 V at J3-4, LD0=LD1=1, LD2 on. LD3 was on once (cause unknown); retest
    30 s untouched + the same switch flips: off. PASS on retest.
  - **[simulated, xsim]** `phase4_loopback_top_tb` 21/21, `phase4_serial_tb` 2/2 (the old RTL fails both).
  - **[Vivado report]** fixed bitstream: WNS +4.001 ns / WHS +0.190 ns.
- Problems / fixes: SERIAL checker compare (fixed, confirmed on the board); LD3 transient on
  pair 4 (open, suspected jumper bumped). Both in `docs/issues.md`.
- Decisions: PC link = JTAG over J17 (Yazan); plan to be approved before any RTL.
- Next steps: EXP-03 on the same wiring (bitstream built); JTAG link plan for approval;
  scope measurements of frequency/duty/edges (CLAUDE.md §7 item 2).

---

## 2026-10-22 (lab PC), Yazan via Claude, branch main
- Goal: handoff steps 1-2 on the Windows lab PC: first xsim runs of the refactored Phase 5
  link and of Phases 6/7, first Vivado builds with the Phase 6/7 files in the project; a
  review of the round-2 RTL that goes to the board (Yazan asked: "go through the repo and
  the changes that were done").
- Done:
  - Ran every sim script with `SIM=xsim` and pytest (results below).
  - `fpga/tb/seq_engine_tb.sv`: declarations of `fetch_step`/`fetch_ready`/`late` and
    `fault_cyc` moved above their first use; xsim refused use-before-declaration, Icarus
    allowed it. No check changed. (`docs/issues.md`)
  - Vivado: rebuilt `phase4_loopback_top`; first build of `phase7_seq_loopback_top`
    (EXP-03's bitstream); first synthesis + place + route (no bitstream, `rxd`/`txd` have
    no pins) of `phase5_link_top` and `phase7_link_top`, from a scratch Tcl script outside
    the repo.
  - `fpga/src/link_ctrl.sv` `read_byte()`: replaced the divide/modulo by `CAP_STRIDE` (24)
    with one constant range compare per cap cell. `phase5_link_top` failed timing by
    6.1 ns because of it. Register map and returned values unchanged. (`docs/issues.md`)
  - Review of the round-2 RTL: `link_frame.sv`, `link_ctrl.sv`, `seq_engine.sv`,
    `seq_bank.sv`, `phase7_seq_loopback_top.sv`, `phase7_link_top.sv`, both Phase 7 XDCs, the
    Phase 5 testbench diffs. Findings below.
- Hardware setup: none (board not connected; nothing programmed).
- Results:
  - **[not hardware]** `python -m pytest nemo_ctl/tests` (from `tools/`): 194 passed, 1 skipped.
  - **[simulated, xsim 2022.1]**, all with Dima's unmodified `sipo_wrapper.sv` where used:
    Phase 3 `sig_cell_tb` 28, `cap_cell_tb` 16, `run_ctrl_tb` 9, `integration_tb` 16;
    Phase 4 `phase4_loopback_top_tb` 21; Phase 5 (refactored) `uart_tb` 12, `link_ctrl_tb` 22,
    `phase5_link_top_tb` 7 (same after the `link_ctrl.sv` fix); **Phase 6
    `phase6_sipo_piso_tb` 69** (first run against Dima's real `sipo_wrapper.sv`, so the
    handoff's "Phase 6 isn't done until it passes xsim" is met); Phase 7 `seq_engine_tb` 40,
    `seq_bank_tb` 10, `phase7_seq_loopback_top_tb` 27, `phase7_link_top_tb` 21 (after the
    testbench fix). Generated packages regenerated byte-identical (tree clean).
  - **[Vivado 2022.1 implementation reports, not measurements]**:

    | Top | Bitstream | WNS / WHS (ns) | LUT / FF / BRAM / IOB | Note |
    |---|---|---|---|---|
    | `phase4_loopback_top` | yes | +3.702 / +0.117 | 440 / 415 / 0 / 24 | identical to 2026-10-19 |
    | `phase7_seq_loopback_top` | yes | +0.248 / +0.167 | 1061 / 755 / 0 / 19 | worst path `u_engine/step_reg` -> `step_reg`, 9 levels |
    | `phase5_link_top` (before fix) | no pins | **-6.148** / +0.094 | 5191 / 8101 / 0 / 24 | 1087 failing endpoints |
    | `phase5_link_top` (after fix) | no pins | +0.238 / +0.023 | — | 0 failing |
    | `phase7_link_top` | no pins | +0.334 / +0.016 | 4496 / 7499 / 2 / 21 | step table in BRAM |

    Warnings reviewed, all expected (unused `cfg_msb_first` in 1-bit cells, `sw[3:0]` unused
    in `phase7_seq_loopback_top` by design, PS7 DRC ZPS7-1 for a PL-only design).
  - Review findings, no other bugs:
    - `link_frame.sv`: FIFO push-when-full-and-pop, LEN > MAX_PAYLOAD, zero-length reads,
      read latency and "respond only while TX idle" all check out. No inter-byte timeout:
      a half-received frame waits for more bytes (design note, not a regression).
    - `link_ctrl.sv`: same register map and behaviour as before the split, apart from the
      timing fix above. The Phase 5 testbench changes are loop restructuring only (no
      `return` in a task), checks unchanged.
    - `seq_engine.sv`: abort paths (ARM/FIRST/RUNNING/WAIT), 1-tick step 0, timeout vs
      condition priority, `after_next` at the end of the table all correct. `n_steps = 0`,
      `COND_AFTER` with arg 0, or `cond_cell >= N_CAP` would hang or index out of range; the
      Python compiler rejects those, and `phase7_link_top` clamps `n_steps` to 1..16.
    - `seq_bank.sv` / `phase7_link_top.sv`: cells only latch the bank on APPLY, writes
      re-copy the bank, table writes refused while busy. Table RAM powers up as 0, so step 0
      before a table load = every pin LOW.
    - `phase7_seq_loopback_top.xdc`: same PACKAGE_PIN/IOSTANDARD lines as
      `phase4_loopback_top.xdc` (empty diff) + PULLDOWN on LA16-20_P, so EXP-03 uses the
      EXP-01 wiring unchanged.
    - `phase7_seq_loopback_top`: its timing margin (+0.248 ns) comes from muxing every
      cell's config and the step condition out of the compile-time table by `step`. A
      bigger table could fail; then register the current step's entry (like `seq_bank`).
- Problems / fixes: the two above (`docs/issues.md`).
- Decisions: fixed the Phase 5 timing in `link_ctrl.sv`'s RTL instead of changing the
  register map stride (the map and the Python encoder stay as they are).
- Next steps: EXP-01 then EXP-03 with someone at the board (both bitstreams are built);
  send Dima the questions; pick the PC-link option for EXP-02/EXP-04.

---

## 2026-10-26, Yazan, branch feature/yazan-gui-waves
- Goal: show the signals' waveforms in the browser editor before the config is saved (Yazan's request).
- Done:
  - `tools/nemo_ctl/waves.py` (new): per-pin edge times of a mode, in ns from RUN, with `sig_cell.sv`'s rules.
    - CLOCK starts high after its delay and runs `cycles` periods (blank = for ever).
    - PULSE: polarity sets the idle level; delay, width, repeat/period.
    - SERIAL: first bit from its delay, next bit on each `data_edge` edge of its clock, MSB/LSB first, back to 0 after the last bit; fewer clock edges than bits is labelled "incomplete".
    - LOW/HIGH constant; BUS groups and the DFT helper as a labelled bus; outputs listed, not drawn.
    - Windowed ([t0, t1] ns); more than 1500 edges in the window -> a `dense` lane. Settings that can't be drawn -> an `error` lane with the reason.
    - Idle level before RUN per lane where the config says it.
  - `tools/nemo_ctl/gui.py`: `POST /api/waves` (the page's unsaved config, mode, window).
  - `tools/nemo_ctl/data/config_gui.html`: Signals panel between the tabs and the blocks.
    - SVG, no libraries: time axis with readable units, a lane per input pin, the label and achieved value per lane, and the idle level drawn dashed before 0.
    - Bus lanes; a band with "zoom in" for lanes too dense to draw.
    - Whole mode / zoom in / zoom out / earlier / later, plus from/to in µs.
    - Redraws after each check (350 ms after typing) and on a mode switch.
  - `tools/nemo_ctl/tests/test_waves.py` (new, 10 tests).
  - Docs: USER_MANUAL §3.5; `tools/nemo_ctl/README.md`.
- Hardware setup: none.
- Results:
  - **[not hardware]** pytest: 234 passed, 1 skipped, in 10 runs in a row. The first full run right after the doc edits had **1 failure that never came back**; I didn't capture which test, so it is unexplained. If a failure shows up again, run `pytest -rf` and record its name.
  - Headless Microsoft Edge on a copy of the example config (with `sipo_in` given real data, 0xA5 / 8 bits):
    - whole mode (0-350 µs): `cs` at 140 µs, the `clk_sipo` (from 2 µs) and `clk_piso` (from 150 µs) bursts, the 1 µs active-low `reset`; free `clk` shown as "zoom in";
    - zoomed 0-12 µs: individual `clk` edges, `sipo_in` = 1,0,1,0,0,1,0,1 changing on `clk_sipo`'s falling edges.
    - Checked against the rendered SVG paths, not only by eye.
  - **Not tested automatically:** clicking the zoom buttons (the zoomed view was checked by opening the page pre-zoomed).
- Problems / fixes:
  - the "idle" label overlapped "0 ns" on the axis; moved and the lead-in widened.
  - Reading the first zoomed screenshot I thought `sipo_in` and `clk` started low. The SVG paths showed they start high, as the data says: my misreading, no bug.
- Next steps: Yazan tries it; merge to `main` when he's happy.

---

## 2026-10-23, Yazan, branch feature/yazan-config-gui
- Goal: an easier way to edit the chip config than the question-by-question wizard (Yazan's request; he picked a browser form).
- Done:
  - `tools/nemo_ctl/gui.py` (new): local server on 127.0.0.1 (standard library). `GET /`, `/api/state`; `POST /api/check` (parse + `validate_config` + the `timing.py` achieved line per setting); `POST /api/save` (refused with errors; `.bak` kept; `save_config`). Host-header and JSON-only checks.
  - `tools/nemo_ctl/data/config_gui.html` (new): the form.
    - Mode tabs, one card per block, one row per pin (inputs and outputs).
    - Type dropdown limited to the pin's allowed types, showing only that type's fields.
    - Live achieved values and per-pin errors/warnings (350 ms after typing).
    - Groups as pins or a bus value; DFT helper as in the wizard.
    - Copy a block from another mode, clear a block, add a mode; Save/Reload, unsaved-changes warning; light and dark theme.
  - `tools/nemo_ctl/config.py`: `config_from_dict()` split out of `load_config` (shared by both).
  - `tools/nemo_ctl/cli.py`: `gui [--config] [--port] [--no-browser]`.
  - `tools/nemo_ctl/tests/test_gui.py` (new, 11 tests):
    - state; check vs `validate_config`; a bad value shown on its pin; an unparseable config;
    - save refused with errors (file untouched, no .bak); save writes and keeps a .bak; unchanged round trip;
    - the real server on a free port (page, state, check) and its Host/Content-Type refusals;
    - the page's script parses (`node --check`); the CLI option.
  - Docs: USER_MANUAL §3.5 + status row + 2 troubleshooting rows; `tools/nemo_ctl/README.md`; `docs/decisions.md`.
- Hardware setup: none.
- Results:
  - **[not hardware]** pytest 224 passed, 1 skipped.
  - Page rendered in headless Microsoft Edge against the example config: 7 block cards, 23 pin rows, 18 achieved-value lines, "0 errors · 4 warnings", matching `validate`. Screenshot checked; the polarity dropdown was clipped and was widened.
  - **Not tested automatically:** clicking and typing in the page (only the API behind it is covered).
- Problems / fixes: the test that pipes the page script to Node failed on Windows' default encoding (cp1252 can't encode "→"); it now passes `encoding="utf-8"`.
- Decisions: `docs/decisions.md` "Config editor as a local browser form".
- Yazan tried it on a copy of the config (`%TEMP%\my_test.yaml`) and asked to push it: `main` fast-forwarded to this branch 2026-10-23 (no partner review, as for the earlier phases).
- Next steps: Rahaf reviews it on `main`; report anything unclear in the form.

---

## 2026-10-22 (night), Yazan, branch main
- Goal: answer the open UART question (EXP-02 / EXP-04) from Yazan's notes on the board kit.
- Done: checked the pasted notes against the official Avnet *ZedBoard Hardware User's Guide*
  v1.1 (2012; the Digilent manual page refused automated download). Results recorded in
  `docs/controller_spec.md` §9:
  - Pmods JA-JD = PL Bank 13 at 3.3 V; JA1 = Y11, JA2 = AA11.
  - J14 USB-UART = PS MIO bank 501 (1.8 V), so it can't be reached from PL without ARM software.
  - J18 sets VADJ for FMC banks 34/35.
  - One correction to the notes: J14 can't be bridged to the PL by an EMIO/XDC change; it needs option (b) (block design + software).
- Hardware setup (reported by Yazan, not measured): the kit has only the 12 V adapter and
  micro-USB cables, no PMOD USB-UART adapter. **J18 (VADJ) was seen on the 2V5 position**;
  it must go back to **1V8**, with SW8 off, before any FMC test (CLAUDE.md §4).
- Results: none measured.
- Decisions: none yet. Pin directions on JA1/JA2 depend on which adapter is used. Choice
  pending: get a 3.3 V USB-UART adapter for JA (option (a)), or switch to the PS (option (b)).
- Next steps: Yazan chooses; then the XDC lines go into `phase5_link_top.xdc` and
  `phase7_link_top.xdc`.

---

## 2026-10-22 (late), Yazan, branch feature/yazan-phase7-link-v2
- Goal: Phase 7 round 2 (link v2): step table over UART, wide data/capture, program-verify over the real link. Decisions (Yazan): step table in RAM + prefetch bank; refactor link_ctrl into a shared link_frame and fix the Phase 5 testbenches.
- Done (commits on this branch): R2.0 Phase 5 TBs Icarus-12-compatible; R2.1 `fpga/src/link_frame.sv` (shared parser, byte bus, 16-byte input FIFO) + `link_ctrl.sv` with packed ports; R2.2 `fpga/src/seq_bank.sv` + `seq_engine.sv` fetch handshake / LATE / preload / START latched during reload; R2.3 `fpga/src/phase7_link_top.sv` (+ `.xdc`: same pins, rxd/txd unconstrained) + `gen_svh.py --phase7-link`; R2.4 `SeqLink` + `cli seq`.
- Results [simulated, Icarus 12]: Phase 5 uart 12, link_ctrl 22, phase5_link_top 7; seq_engine 40, seq_bank 10, phase7_seq_loopback_top 27, phase7_link_top (real UART) 21; pytest 194 passed, 1 skipped. Problems found and fixed: docs/issues.md (Icarus 12 ports; write latency LEN+4). Also fixed, not yet in issues.md: START dropped during the new reload state; SOF lost while a write was on the bus (-> FIFO).
- R2.5 docs (same day, after a pause): `docs/link_register_map.md` (frame-engine changes + the v2 map and step-entry layout), USER_MANUAL §8.6 (`cli seq`, `SeqLink`, LATE) + status row, 2 troubleshooting rows, quick reference, §7.5 corrected; `docs/experiments/EXP-04_phase7_link_sequencer.md` (new, PENDING, blocked on EXP-02's UART pin); `docs/issues.md` (dropped START, lost SOF); `docs/decisions.md` (RAM + prefetch, shared frame engine, v2 command meanings); CLAUDE.md §6 (3 rows) / §7; `tools/nemo_ctl/README.md` (`link.py` row added; stale `types.py` -> `pin_types.py`; `cli.py` now lists `link`/`seq`); `docs/HANDOFF.md`. The manual's CLI output lines were checked against the real CLI code over the test fake (`STATUS: done; step 0, last step 5`, `data_in: capture 0xA5, edges 0, level 0`); the board would also show `late` (RTL testbench STATUS 00100100).
- Still open: xsim runs of Phases 5-7 (lab PC), Vivado build of `phase7_link_top`, EXP-04 (needs EXP-02's UART pin).
- Merged: Yazan asked to merge; `main` fast-forwarded to this branch (`origin/main` hadn't moved since `bbb80ae`). No partner review (`docs/decisions.md`).

---

## 2026-10-22 (end of session), Yazan, branch main
- Goal: Yazan asked to push Phase 6 and Phase 7 to `main` with the handoff and every doc up
  to date.
- Done:
  - Fast-forwarded `main` to `feature/yazan-phase7-sequencer`, which contains all of
    `feature/yazan-phase6-sipo-piso`. `origin/main` hadn't moved since `6a887d6`, so no
    merge commit and nothing of Rahaf's to reconcile. PR #1 had no reviews; GitHub marks it
    merged once `main` contains its commits.
  - `docs/HANDOFF.md` rewritten for the state after Phases 6 and 7 (round 1).
  - `README.md`: status paragraph (was "Phase 1 is done"), scripts/docs/config/tools lines of the layout, test and sim commands (pytest command checked from the repo root: 176 passed, 1 skipped).
  - Stale references fixed: CLAUDE.md §7 item 5 and USER_MANUAL §7.5 now say the link
    widening is Phase 7 round 2; `docs/link_register_map.md` no longer calls it "Phase 6/8
    work"; the "Currently working on" table (Phase 6 no longer under Rahaf; nothing open
    for Yazan); `docs/decisions.md` (outcome of the review-order override, and this push).
  - Checked, no change needed: `docs/USER_MANUAL.md` status table, EXP-01/02/03 (all still
    PENDING), `docs/pin_verification.md` (no new measurements), `docs/questions_for_dima_2026-10-22.md`
    (still not sent), `docs/controller_spec.md`. `docs/NEMO_FPGA_bringup_log.tex` is the
    frozen September bring-up report (never updated since it was imported); left as is.
- Hardware setup: none.
- Results: before the push, from the branch tip: pytest 176 passed, 1 skipped; Icarus 12
  sims Phase 3 28/16/9/16, Phase 4 21/21, Phase 6 69/69, Phase 7 31/31 + 27/27
  [simulated]. Phase 5 `uart_tb` doesn't elaborate under Icarus 12 (known, unchanged).
- Decisions: pushed to `main` without Rahaf's review, at Yazan's request (`docs/decisions.md`).
- Next steps: see `docs/HANDOFF.md` "What to do next".

---

## 2026-10-22 (later), Yazan, branch feature/yazan-phase7-sequencer
- Goal: Phase 7, mode sequencer (`generic_controller_prompt.md` §3): a mode as an ordered
  list of steps, each = pin config + duration or "wait until capture condition";
  program-verify loop driven from Python; exit [simulated] then [measured on board] with
  loopback.
- **Process:** Yazan asked to start Phase 7 while PR #1 (Phase 6) is still unreviewed,
  overriding Rahaf's "stop for approval after each phase" for this phase. Branch cut from
  `feature/yazan-phase6-sipo-piso`. Two decisions put to Yazan before any code (CLAUDE.md §8:
  plan first): sequencer in **FPGA hardware** (chosen) vs Python-only; scope **engine +
  loopback top this round, link v2 later** (chosen). See `docs/decisions.md`.
- Done:
  - **7.1** `tools/nemo_ctl/sequence.py` (new): step format `set` / `capture` / `until`
    (`after`, `done`, `captured`, `edges`, `level`, + `timeout`); a `Target` describing a
    top's cells (`PHASE7_LOOPBACK`: sig `clk rst data cs en` on FMC 0-4, cap `clk_in ...
    en_in` on 16-20, data shifts on clk falling, data_in captures on clk rising); validator
    (step 0 sets every cell; waits need a timeout; `done`/`captured` cell must be applied
    in the same step and able to finish; mode checks; widths; 50 MHz limit, >10 MHz warning;
    <=16 steps); tick compiler with a time scale; step summary; `program_verify()` against a
    `Sequencer` protocol; `python -m nemo_ctl.sequence <yaml>` check command.
    `config/phase7_seq_loopback.yaml` (new): 6-step demo (idle 1 s -> rst pulse -> load
    0xA5 on a 4 Hz x8 clock until captured -> cs pulse until 1 edge seen -> en_in level ->
    hold 2 s), ~6 s at human speed.
  - **7.2** `fpga/src/seq_engine.sv` (new): PRELOAD step 0 after reset (RUN low; pins at
    step 0's idle levels), START applies step 0 to all cells then RUN, masked APPLY per
    step (unlisted cells untouched), tick-exact AFTER, waits ignored for 2 ticks, timeout
    -> FAULT, abort, end/fault/abort: RUN low + step 0 re-applied to sig cells only.
    `fpga/tb/seq_engine_tb.sv` (new) with real cells.
  - **7.3** `tools/nemo_ctl/gen_svh.py --phase7` (+ `--time-scale`, `--out`; refuses a
    scaled package without `--out`) -> `fpga/src/gen/phase7_cfg_pkg.sv` (per-step packed
    vectors). `fpga/src/phase7_seq_loopback_top.sv` + `fpga/constraints/phase7_seq_loopback_top.xdc`
    (new): engine + 5 sig/5 cap cells on pairs 0-4, sw[4] START/ABORT (2-FF sync + 20 ms
    debounce), LEDs LD0-2 step, LD3 busy, LD4 done, LD5 fault, LD6 data match, LD7 aborted.
    XDC pin/IOSTANDARD lines identical to Phase 4 (checked with `diff`), plus PULLDOWN on
    LA16-20_P. `fpga/tb/phase7_seq_loopback_top_tb.sv` (new), `scripts/run_phase7_sim.sh`
    (new). `docs/experiments/EXP-03_phase7_sequencer_loopback.md` (new): procedure +
    PENDING results table.
  - **7.4** docs: USER_MANUAL §8 Phase 7 (old §8/§9 -> §9/§10), status table, 3
    troubleshooting rows, quick reference; CLAUDE.md §6 (2 rows) and §7 item 8;
    `tools/nemo_ctl/README.md`; `docs/issues.md` (3), `docs/decisions.md` (3).
- Hardware setup: none (laptop, no board).
- Results:
  - **[simulated, Icarus 12]** `scripts/run_phase7_sim.sh`: `seq_engine_tb` **31/31**
    (every step boundary to the tick: AFTER 7 = 7 ticks, done/edges/level/captured end the
    step the tick after the event, 1-tick step, clock from step 0 never restarted over 7
    periods, fault 51 ticks after the step's apply with timeout 50, abort, start-while-busy
    ignored, 1-step table, captures kept after the end); `phase7_seq_loopback_top_tb`
    **27/27** on the x1e-4 package (preload rst=1, debounce glitch ignored, every step
    length, rst pulse 5000 ticks, 8 clk edges all 2500-tick periods, data_in = 0xA5 on the
    8th rising edge, cs width, confirm step 3 ticks, LEDs, pulled J2-20 -> FAULT at step 4,
    abort at step 2).
  - **[not hardware]** pytest **176 passed, 1 skipped** (+32 for Phase 7).
  - Regression [simulated, Icarus 12]: Phase 3 28/16/9/16, Phase 4 21/21, Phase 6 69/69;
    `nemo_cfg_pkg.sv` / `phase6_cfg_pkg.sv` regenerate unchanged.
  - Every USER_MANUAL §8 command run as written (check command good + bad, `--phase7`,
    refused `--time-scale` without `--out`, `run_phase7_sim.sh`).
  - **Not done:** Vivado build of this top, xsim, EXP-03 on the board (the Phase 7 hardware
    exit criterion), link v2.
- Problems / fixes (detail in `docs/issues.md`):
  - **Real design bug, caught by the top testbench:** the end-of-run re-apply also
    re-applied the cap cells and wiped `data_in`'s result. Now sig cells only.
  - Testbench race: monitors on posedge were +/-1 tick off; moved to negedge. Plus two test
    mistakes of mine (a "never-true" level that was briefly true, an unreachable period
    count) and a check that ran before its monitor had recorded the value.
  - Floating input on a pulled jumper would make the fault test random -> PULLDOWN in XDC.
  - Small: the check command split errors on "; " (one message contains it) -> one error
    per line; an edit of mine put a raw newline in a string literal (SyntaxError, caught by
    the tests before commit).
- Decisions: `docs/decisions.md` (3 new entries).
- What a pass looks like on hardware: EXP-03 §4/§5. LEDs step 0,1,2,3,5 over ~6 s, then
  LD4 + LD6 on; pulled J2-20 -> LD5 with step 4; sw[4] down mid-run -> LD7.
- Next steps: EXP-03 on the lab PC (sim in xsim, build, program, run 3 runs, fill §5);
  Phase 7 round 2 = link v2; Rahaf reviews PR #1 and then this branch.

---

## 2026-10-22, Yazan, branch feature/yazan-phase6-sipo-piso
- Goal: start Phase 6 (SIPO/PISO against Dima's model) with step 6.1 of the plan approved
  2026-10-19 (`docs/HANDOFF.md`): the Python frame packer/decoder, timing profile builders
  and validator rules. Done on Yazan's laptop: Python only, no Vivado/Icarus/yosys.
- Done:
  - `tools/nemo_ctl/sipo_piso.py` (new):
    - SIPO: `pack_sipo_frame(sel_lo, slices)` / `unpack_sipo_frame` for the 136-bit
      `parallel_out` (`sel[7:0]` = bits [7:0], slice k = bits [8+16k +: 16], k = 0..7);
      `sipo_tx_bits` (transmit order, bit 135 first); `dima_sel_after(frame, n)` gives
      `sipo_wrapper.sv`'s `sel[23:0]` after n `phirst` edges **with Dima's quirks as
      written**: n=0 -> `sel[23:8]`=0 (Q1), n=1..7 -> slice n, n>=8 -> `DimaModelUndefined` (Q2).
    - PISO: `PisoStage(out1, tdc_out1, out0, tdc_out0)` with `piso.sv`'s stage layout
      ([41:28], [27:21], [20:7], [6:0]); `encode_piso_frame` / `decode_piso_frame` for the
      168-bit frame, PISO0 first, first bit received = bit 167 (what `cap_cell` CAP_W=168
      msb_first leaves in `capture_reg`).
    - Profiles in ticks: `build_sipo_load(freq, ...)` (rst_sipo low pulse at RUN; clk_sipo
      136 cycles starting 1 us after reset releases; sipo_in 2 ticks before clk_sipo; cs one
      period after the 136th rising edge) and `build_piso_read(freq, ...)` (clk_piso 168
      cycles; shift rises mid first low phase, width 167 periods).
    - Rules: `check_sipo_load` (136 cycles, clock starts after reset releases, sipo_in
      starts before rising edge 1, cs after the last falling edge) and `check_piso_read`
      (168 cycles, shift rises in the first low phase, shift still high at the last
      falling edge, clk_piso high time >= 3 ticks of FPGA sync latency + `chip_delay_ticks`).
  - `tools/nemo_ctl/tests/test_sipo_piso.py` (new, 23 tests): round trips, field
    placement against Dima's RTL, Q1/Q2 behaviour, and a **tick-level Python model** of
    sig_cell/cap_cell pin timing driving `sipo.sv`/the 4-stage `piso2` chain. The model
    shows the default profiles load/read the right frame at 100 kHz, 1 MHz and 10 MHz,
    and that each profile the rules reject really corrupts the frame (late sipo_in,
    early cs, early/short shift, too-short clk_piso high time).
- Hardware setup: none.
- Results:
  - **[not hardware, not RTL simulation]** `python -m pytest tools/nemo_ctl/tests`:
    124 passed, 1 skipped (101 existing + 23 new; same expected skip as before).
    The tick-level model is my reading of the RTL, written in Python. It is **not** a
    simulation of the real `.sv` files. That is step 6.4 (xsim).
- Problems / fixes: two of my own test-model mistakes, fixed before commit. (1) The model
  missed clk_piso's rising edge 1 when `clk_delay=0` because it started at tick 1; pins
  idle low before RUN, so tick -1 is now treated as 0. (2) A test that set shift to rise
  on the same tick as the load edge: that is a genuine race with no defined outcome (the
  rule rejects it, correctly), so the test now uses shift already high before edge 1.
- Decisions:
  - Data-change/sampling edges are not parameters of the 6.1 builders; the profiles
    implement the falling-edge convention from the approved plan. They become config
    fields (marked UNCONFIRMED) in 6.2's YAML, as planned.
  - The capture rule uses 3 ticks of FPGA latency (2-FF sync + cap_cell input register),
    1 more than the tick model strictly needs: margin for the output/input IOB registers.
  - Working on a feature branch, not pushing to `main` directly: Rahaf's direct-to-main
    rule was for her work; this is Yazan's laptop and the WORKLOG still lists Phase 6
    under Rahaf.
- 6.1 pushed to `origin/feature/yazan-phase6-sipo-piso` (`7bc666c`).
- **Step 6.2 (same session):**
  - `config/phase6_sipo_piso.yaml` (new): `profiles.SIPO_LOAD` (rst_sipo PULSE active_low
    100 ns @0; clk_sipo CLOCK 1 MHz, 136 cycles @1.1 us; sipo_in SERIAL 136 bits MSB-first,
    data_edge falling, @1.08 us, frame sel_lo=0xA5 + slices 0x1111..0x8888; cs PULSE
    active_high 1 us @137.1 us) and `profiles.PISO_READ` (rst_piso HIGH; clk_piso CLOCK
    1 MHz, 168 cycles @0; shift PULSE active_high 167 us @750 ns; piso_out CAPTURE serial
    168 bits MSB-first, edge falling, chip_delay 0 ns), plus `testbench.piso_stages` (4
    stage values for 6.4). The numbers are exactly `build_sipo_load("1MHz")` /
    `build_piso_read("1MHz")`. UNCONFIRMED fields are marked in the file.
  - `tools/nemo_ctl/sipo_piso.py`: `load_phase6_config()` parses the YAML, checks pin
    set/types, SERIAL/CAPTURE widths and bit order, edges and polarities, converts the
    settings to `SipoLoadTiming`/`PisoReadTiming`, and runs the 6.1 rules. Errors raise
    `FrameError` listing every problem; UNCONFIRMED choices come back as warnings.
  - `tools/nemo_ctl/gen_svh.py`: new `--phase6` option (argparse; no option still makes
    the Phase 4 package exactly as before) -> `generate_phase6()` writes
    `fpga/src/gen/phase6_cfg_pkg.sv`: per-pin sig_cell localparams (TYPE, IDLE, DELAY,
    PARAM_A/B, CYCLES, BITS) for the 7 driven pins, `SIPO_IN_DATA` (136 bits),
    `SIPO_IN_SHIFT_ON_FALLING` / `PISO_OUT_CAPTURE_ON_FALLING` (strobe edge selects for 6.3),
    piso_out cap_cell params, and testbench vectors: `SIPO_TB_SEL_AFTER_0..7` (Dima's
    `sel[23:0]` after n phirst edges, Q1 quirk included) and `PISO_TB_STAGE{0..3}_*` +
    `PISO_TB_FRAME`.
  - `fpga/src/gen/phase6_cfg_pkg.sv` (new, generated and committed like `nemo_cfg_pkg.sv`).
  - `tools/nemo_ctl/tests/test_phase6_config.py` (new, 20 tests): config == 1 MHz builders;
    13 broken variants rejected with the right message (early cs, 135 cycles, late
    sipo_in, LSB-first, early/short shift, rising capture edge, chip_delay too big, wrong
    capture width, missing pin, wrong type, 3 stages, out-of-range stage value); non-RTL
    polarity and rising data edge only warn; generated localparams/vectors parsed back
    and compared.
- Results (6.2):
  - **[not hardware, not RTL simulation]** `python -m pytest tools/nemo_ctl/tests`:
    144 passed, 1 skipped (101 existing + 23 from 6.1 + 20 new).
  - Regenerating the Phase 4 package (`python -m nemo_ctl.gen_svh`) after the change:
    `fpga/src/gen/nemo_cfg_pkg.sv` byte-identical (no git diff).
  - **Not checked:** `phase6_cfg_pkg.sv` hasn't been parsed by any HDL tool (none on this
    laptop). `scripts/create_project.tcl` globs `fpga/src/gen/*.sv`, so Vivado will also
    compile this package into the Phase 4 project. It's plain localparams, but **if the
    Phase 4 build on the lab PC breaks, check this file first.** Step 6.3/6.4 in xsim
    will parse it.
- Problems / fixes (6.2): my test helper's regex only parsed `'h` literals and missed
  `1'b1`; fixed in the test. A first attempt to edit `gen_svh.py` through an inline bash
  heredoc failed on shell quoting and changed nothing (checked with `git status`); redone
  with the editor.
- Decisions (6.2): see `docs/decisions.md`, "Phase 6: SIPO/PISO as profiles of the
  generic cells, in their own config package".
- 6.2 pushed (`c3296c9`).
- **Steps 6.3 + 6.4 (same session):**
  - Tooling: installed **Icarus Verilog 12** on this laptop (`winget install Icarus.Verilog`,
    v12.2022.06.11, to `C:\iverilogin`). `scripts/sim_lib.sh`: also looks for Icarus in
    `/c/iverilog/bin`; `sim_python` now picks the interpreter that can `import yaml`
    (this laptop's `python3` is 3.13 without the packages). Baseline under Icarus 12:
    Phase 3 28/16/9/16 and Phase 4 21/21 pass; **Phase 5 `uart_tb` doesn't elaborate**
    (`return` in a task, unsupported by Icarus 12; not changed, see `docs/issues.md`).
  - `fpga/src/phase6_sipo_piso_top.sv` (new, 6.3): `run_ctrl` + 7 `sig_cell`s (rst_sipo,
    clk_sipo, sipo_in with SERIAL_W=136, cs, rst_piso, clk_piso, shift) + 2-FF sync +
    `cap_cell` CAP_W=168 on piso_out, all from `phase6_cfg_pkg`. sipo_in's shift_strobe and
    piso_out's capture_strobe are clk_sipo/clk_piso falling_edge (rising if the package's
    `*_ON_FALLING` = 0). Chip pins are plain ports: **simulation top, no XDC** (no
    chip-pin -> LA_P map yet).
  - `fpga/tb/phase6_sipo_piso_tb.sv` (new, 6.4): the top driving Dima's `sipo_wrapper`
    (+ `sipo`) and four chained `piso2` (PISO3.prev=0 ... read PISO0); `phirst` and a lumped
    transport delay on piso_out (chip delay) from the TB. One APPLY, three RUNs: chip delay
    0 ns, 400 ns (both must pass), 600 ns (must corrupt the frame: rule limit is
    50 - 3 ticks = 470 ns). Per RUN: 136 clk_sipo / 1 cs / 168 clk_piso rising edges,
    rst_sipo released before clk_sipo edge 1, sipo_in as sampled == frame, Dima's
    `parallel_out` == frame, `sel` before/after each of 7 phirst edges, Q2 on the 8th,
    shift=0 at clk_piso edge 1 and 1 at the other 167, captured frame == `PISO_TB_FRAME`,
    all pins idle after STOP.
  - `fpga/tb/tower_cell_stubs.sv` (new): `ANTENNA_18_SVT_WTN` (sink),
    `DLY3_X4_18_SVT_WTN` (zero-delay buffer).
  - `fpga/tb/sipo_wrapper_icarus_shim.sv` (new): Icarus 12 can't elaborate Dima's
    `sipo_wrapper.sv` (`sel` driven by an assign and an always_ff); this is his module
    with only that driver split. Used **only** when SIM=icarus; xsim gets the original.
  - `scripts/run_phase6_sim.sh` (new): regenerates `phase6_cfg_pkg.sv`, then runs the TB
    with Dima's `piso.sv` / `sipo.sv` straight from `fpga/reference/dima_blocks/`.
  - `tools/nemo_ctl/sipo_piso.py`: `dima_sel_after(frame, n, prev_frame=0)`, Q1 corrected
    (below). `gen_svh.py`: comment on `SIPO_TB_SEL_AFTER_*` updated. Test added for the
    reload case.
- Results (6.3/6.4):
  - **[simulated, Icarus 12, Dima's `piso.sv`/`sipo.sv` unmodified, `sipo_wrapper` via the
    one-change stand-in]** `scripts/run_phase6_sim.sh`: **69/69 checks pass**. RUN 1
    and 2 capture `168'hfffc02469fc001ab5550155555000102001fffff00` == `PISO_TB_FRAME`;
    RUN 3 (600 ns) captures `7ffe01234fe000d5aaa80aaaaa800081000fffff80` (the expected frame
    shifted by one bit), as `check_piso_read` predicts. Dima's `parallel_out` ==
    `136'h88887777666655554444333322221111a5` every RUN.
  - **[not hardware]** pytest 144 passed, 1 skipped. Phase 3/4 sims unchanged (above).
  - **Not run:** xsim, so neither the run against Dima's unmodified `sipo_wrapper.sv` nor
    xsim's stricter checks have happened yet.
- Problems / fixes (6.3/6.4), detail in `docs/issues.md`:
  - **Q1 is not what we thought** (finding about Dima's RTL): on a reload, `sel[23:8]`
    before the first phirst is the *previous* load's slice 0 (RUN 2: `1111a5`), not 0.
    The nonblocking reset branch reads `parallel_out` before `sipo.sv`'s reset clears it.
    Model, TB and `docs/controller_spec.md` Q1 corrected; my first TB expectation (always
    0) was wrong.
  - **Before the first APPLY, rst_sipo/rst_piso are 0 (chip resets asserted)**: the
    `sig_cell` reset value. Probably the safe state, but it disagrees with the spec's
    "idle HIGH"; open for Phase 8's power-up checklist. My first TB check expected high;
    changed to check and record the actual behaviour.
  - Icarus 12 `vvp` crashed on `fork ... join_any` + `disable`; replaced with a polling loop.
  - Two scripting slips of mine (a file-list edit that didn't apply, a sed quoting error),
    both caught by re-running; neither reached a commit.
- Decisions: `docs/decisions.md`, "Phase 6 sims on Yazan's laptop: Icarus 12 from winget,
  with a one-change sipo_wrapper stand-in".
- What a pass looks like on hardware: nothing yet. This top has no pins until the chip-pin
  -> FMC map exists; Phase 6 has no hardware exit criterion of its own.
- Next steps:
  1. Run `scripts/run_phase6_sim.sh` with `SIM=xsim` on the lab PC (uses Dima's unmodified
     `sipo_wrapper.sv`). Phase 6 isn't done until that passes too.
  2. 6.5: USER_MANUAL Phase 6 section, CLAUDE.md §6/§7 (new files, Q1 correction).
  3. Questions for Dima: Q1 as corrected (and how an async reset that loads data was
     synthesized), sipo_in/piso_out edges, chip delay.
  4. Still agree the Phase 6 split with Rahaf: the WORKLOG lists Phase 6 under her too.
- 6.3/6.4 pushed (`a5588ac`).
- **Step 6.5 (same session), docs:**
  - `docs/USER_MANUAL.md`: new **§7 Phase 6** (the two profiles pin by pin, frame fields,
    UNCONFIRMED fields, `gen_svh --phase6` and what it refuses, building/decoding frames
    in Python, `run_phase6_sim.sh` and the expected 69 checks, why RUN 3's wrong frame
    is a pass, the Icarus stand-in, what Phase 6 doesn't do). Status table (Phase 6 row),
    §1 setup note for Windows + Icarus 12, 4 troubleshooting rows, 4 quick-reference rows.
    Troubleshooting -> §8, quick reference -> §9 (no cross-references pointed at the old
    numbers).
  - Every command in the new §7 was run as written and gave the output shown: good
    config -> one UNCONFIRMED warning + `wrote ...`; `cs` at 100 us through the real CLI
    `main()` -> the quoted `error: SIPO_LOAD: cs rises at tick 10000 ...`, exit 1,
    package file unchanged; the Python snippet's three outputs; `run_phase6_sim.sh` ->
    `ALL TESTS PASSED (69 checks)` [simulated, Icarus 12].
  - `CLAUDE.md`: §4 Windows-laptop Icarus 12 note; §5 the corrected Q1 fact, tagged
    [simulated]; §6 `phase6_sipo_piso_top.sv` row; §7 item 5 rewritten (done in
    simulation; open items listed).
  - `tools/nemo_ctl/README.md`: rows for `gen_svh.py` and `sipo_piso.py`. Not fixed, outside
    Phase 6: that table was already missing `link.py` and still says `types.py` for
    `pin_types.py`.
- Phase 6 status: **not done** by the project's rules. It needs (1) the xsim run with
  Dima's unmodified `sipo_wrapper.sv` on the lab PC, (2) someone other than the author
  following USER_MANUAL §7 successfully (Rahaf's rule), (3) approval before Phase 7
  (Rahaf's phase-gate rule). Merge to `main` via PR, reviewed by Rahaf (CLAUDE.md §10).
- `docs/questions_for_dima_2026-10-22.md` (new): draft, **not sent**. Our current
  SIPO/PISO sequence, for Dima to confirm, plus 16 questions: Q1 as corrected (and how a
  data-loading async reset synthesized), Q2/Q3, sipo_in/cs/PISO timing, clk_piso ->
  piso_out delay (sets max clk_piso), Q5 column mapping, reset polarity, power-up state
  (resets asserted until APPLY), 1.8 V levels / max clocks, rst_sipo pad, and short
  carry-overs Q4/Q6/Q10. Wording checked against the generated numbers (cs is 1 us after
  the 136th rising edge).
- Opened **PR #1** (`feature/yazan-phase6-sipo-piso` -> `main`,
  https://github.com/yazanrabea/FPGA-controller/pull/1), review requested from Rahaf
  (`RahafAburaya`). Installed GitHub CLI on this laptop for it (`winget install GitHub.cli`,
  v2.103.0; signed in as `yazanrabea`). The PR checklist lists what's still open: xsim run,
  a Vivado rebuild of Phase 4, the Icarus 12 `uart_tb` limit, the manual walkthrough, and
  Phase 6 approval.

---

## 2026-10-19, Rahaf, branch main
- Goal: re-run every Phase 3-5 simulation and the Python test suite on the lab PC before
  starting Phase 6 (SIPO/PISO); propose the Phase 6 plan; then Phase 6 step 6.0 (make the
  sim flow run on the lab PC).
- Done:
  - Lab PC is Windows 11 with **Vivado 2022.1 installed** (`C:\Xilinx\Vivado\2022.1`)
    but no Icarus Verilog/yosys, so the `scripts/run_phase*.sh` scripts (Homebrew paths)
    couldn't run here. First run: same file lists, same order, with Vivado's simulator
    (`xvlog -sv` / `xelab` / `xsim -R`) from a throwaway script outside the repo.
    Installed `tools/requirements.txt` with pip (`python`, not `python3`: on this PC
    `python3` is the Windows Store stub).
  - Step 6.0 (approved by Rahaf), fixes for everything that run turned up:
    - `scripts/sim_lib.sh` (new): picks Icarus if installed, otherwise Vivado xsim
      (Git Bash on Windows, native paths via `cygpath`); `SIM=icarus|xsim` forces one.
      `run_phase3_sims.sh`, `run_phase4_sim.sh`, `run_phase5_link_sim.sh` now use it;
      Phase 3 skips the yosys estimate with a message if yosys is missing; Phase 4 uses
      `python3` only if it really works, else `python`. Also fixed `run_phase4_sim.sh`'s
      header comment, which pointed at a nonexistent "EXP-05" (it's EXP-01).
    - `fpga/tb/link_ctrl_tb.sv`: mock uart_tx `always_ff` -> `always` (see issues.md).
    - `tools/nemo_ctl/gen_svh.py`: emits `` `timescale 1ns / 1ps `` in
      `nemo_cfg_pkg.svh`, and writes the `// Source:` path with `/` on every OS.
      `fpga/src/gen/nemo_cfg_pkg.svh` regenerated (only change: the timescale line).
    - `.gitattributes` (new): `*.sh text eol=lf`. This PC has `core.autocrlf=true`,
      which would check the scripts out with CRLF and break them in Git Bash.
    - `docs/USER_MANUAL.md` §1 + troubleshooting, `docs/issues.md`, `CLAUDE.md` §4:
      the xsim fallback and the Windows notes.
- Hardware setup: none.
- Results:
  - **[not hardware]** `python -m pytest tools/nemo_ctl/tests`: 101 passed, 1 skipped
    (`test_link.py:382`, only meaningful when pyserial is *not* installed; expected).
    Same after step 6.0.
  - **[simulated, xsim 2022.1]** before 6.0: `sig_cell_tb` 28/28, `cap_cell_tb` 16/16,
    `run_ctrl_tb` 9/9, `integration_tb` 16/16, `uart_tb` 12/12, `phase5_link_top_tb` 7/7;
    `phase4_loopback_top_tb` and `link_ctrl_tb` failed to *elaborate* (they pass under
    Icarus).
  - **[simulated, xsim 2022.1]** after 6.0, through the repo scripts themselves: all 8
    pass -- the 6 above plus `phase4_loopback_top_tb` 21/21 and `link_ctrl_tb` 22/22.
  - yosys utilization estimate not run (yosys not installed here).
- Problems / fixes: see `docs/issues.md`, "Testbenches passed in Icarus but failed to
  elaborate in Vivado xsim".
- Decisions:
  - Rahaf asked for direct pushes to `main` after each passing step (commit,
    `git pull --rebase origin main`, push), in place of the CLAUDE.md §10 PR flow, and a
    stop for approval after each phase. That covers the shared files touched here
    (`CLAUDE.md`, scripts, `gen_svh.py`) too; she approved that explicitly.
  - Phase 6 plan approved: express SIPO load / PISO read with the existing generic cells
    (no dedicated engines), compile-time config like Phase 4, testbench against Dima's
    unmodified blocks. Widening the Phase 5 link's 16-bit DATA/CAPTURE registers for
    136/168-bit frames is deferred to Phase 7.
  - ZedBoard is available in the lab, so EXP-01 (Phase 4 hardware run) goes next, built
    with the Vivado on this PC.
- EXP-01 preparation (Phase 4 hardware run, first Vivado build of this top):
  - First `create_project.tcl -tclargs phase4_loopback_top build` failed synthesis:
    `nemo_cfg_pkg` not declared (Vivado never compiles `.svh` files). Fixed by generating
    `fpga/src/gen/nemo_cfg_pkg.sv` instead (`git mv`, `gen_svh.py`, `create_project.tcl`,
    `run_phase4_sim.sh`, CLAUDE.md §6, USER_MANUAL, EXP-01, controller_spec,
    `config/phase4_loopback_test.yaml` comment). Details in `docs/issues.md`.
  - Rebuilt: bitstream `build/phase4_loopback_top/phase4_loopback_top.runs/impl_1/phase4_loopback_top.bit`.
    **[Vivado implementation report, not a measurement]**: all timing constraints met,
    WNS +3.702 ns / WHS +0.117 ns; 440 LUTs, 415 FFs, 24 bonded IOBs. Warnings reviewed,
    all expected (unused `cfg_msb_first` in 1-bit cells, `led[7:5]` tied 0, PS7 DRC
    ZPS7-1 normal for a PL-only design).
  - Cross-checked `fpga/constraints/phase4_loopback_top.xdc`: `clk`, `sw[4:0]`,
    `led[7:0]` and `fmc_pins[0..4,16..20]` are identical to `fmc_clock_loopback.xdc`
    (the XDC behind the measured pair 0 result).
  - Added `scripts/program_board.tcl` (programs the PL over JTAG with a top's built
    bitstream). Ran it: `no JTAG target found` -- board not powered/connected yet. EXP-01
    measurements not started.
- Next steps: Rahaf powers the board (VADJ 1V8, jumpers per EXP-01 §1, `sw` all 0) and
  connects PROG J17; program with `program_board.tcl`; run EXP-01 §3; then Phase 6
  steps 6.1-6.5.
- Session end: a background `git push` was killed by Claude Code (PC low on memory)
  while it waited on Git Credential Manager. Rahaf then asked to push everything and
  write a handoff for another agent: `docs/HANDOFF.md` rewritten for the current state
  (lab PC setup, EXP-01 steps, approved Phase 6 plan with the timing analysis).

---

## 2026-10-16, Rahaf, branch feature/rahaf-user-manual
- Goal: Phase 5 of `generic_controller_prompt.md` — the runtime link ("implement the
  link chosen in Phase 0 [USB-UART on a PMOD]... Python: `nemo_ctl.link` with
  `send_config(mode)`, `apply()`, `run()`, `stop()`, `read_captures()`... exit: change a
  clock frequency from the PC without re-synthesis and see it on the multimeter/scope").
  Started before Phase 4's own hardware exit criterion was met, on Rahaf's explicit
  instruction to deviate from the normal phase-gate rule and proceed anyway.
- Done:
  - `docs/link_register_map.md`: the concrete byte-level register map (superseding
    `controller_spec.md` §7-8's draft sketch) — global SCRATCH/RUN_CTRL/APPLY_CTRL/
    STATUS at 0x0000-0x0003, 5 `sig_cell` regions at 0x0010 (24 B stride: CTRL/DELAY/
    PARAM_A/PARAM_B/CYCLES/DATA/BITS), 5 `cap_cell` regions at 0x0100 (24 B stride:
    writable CTRL/BITS + read-only STATUS_FLAGS/EDGE_COUNT/PERIOD_TICKS/HIGH_TICKS/
    CAPTURE_REG), and the frame format (SOF/CMD/ADDR/LEN/DATA/CHECKSUM). Documented
    limitation: DATA/CAPTURE_REG fixed at 16 bits — fine for the 5 debug cells, not
    enough for the real chip's 136-bit SIPO data (flagged as later-phase work).
  - `fpga/src/uart_tx.sv` + `uart_rx.sv`: parameterized 8-N-1 UART, `fpga/tb/uart_tb.sv`
    **[simulated]**, 12/12 checks (round trip, busy-flag timing, back-to-back bytes,
    send-while-busy ignored, bad-stop-bit -> frame_error).
  - `fpga/src/link_ctrl.sv`: frame parser + flat register file + all 8 commands
    (WRITE_REG/READ_REG/APPLY/RUN/STOP/STATUS/READ_CAPTURE, LOAD_MODE permanently
    NACKed as unimplemented) + NACK on bad checksum or unknown CMD.
    `fpga/tb/link_ctrl_tb.sv` **[simulated]**, 22/22 checks, byte-level (bypasses real
    UART timing — that's `uart_tb.sv`'s job).
  - `fpga/src/phase5_link_top.sv` + `fpga/constraints/phase5_link_top.xdc`: reuses
    Phase 4's exact 5 debug cells (test_clock/pulse/serial/low/high) and clk/sw/led/
    fmc_pins pin assignments, but RUN/STOP/APPLY and every cfg_* field now come from
    `link_ctrl.sv`'s register file instead of compile-time constants. `rxd`/`txd`
    deliberately left unconstrained in the XDC — PMOD bank voltage still unconfirmed
    from Phase 0, see Decisions below. `fpga/tb/phase5_link_top_tb.sv` **[simulated]**,
    7/7 checks, a mock PC with its own real UART pair (not the byte-level shortcut) —
    centerpiece test directly exercises the exit criterion: configure test_clock to a
    20-tick period, RUN, measure period=20 on the loopback pin, then *while still
    RUNning, no STOP* write a new 40-tick period and APPLY again, re-measure period=40.
  - `scripts/run_phase5_link_sim.sh`: runs all three testbenches above in order.
  - `tools/nemo_ctl/link.py`: Python client for the protocol — `build_frame`/
    `parse_frame`/checksum, `Transport` protocol + `SerialTransport`/`open_serial`
    (pyserial imported lazily, so nothing else needs it installed), `SigCellConfig`/
    `CapCellConfig`/`CapCellStatus` encode/decode, and `Link` with
    `write_reg`/`read_reg`/`apply`/`run`/`stop`/`status`/`read_capture_raw` plus the
    debug-harness helpers `send_cell_config`/`send_cap_config`/`send_config`/
    `read_captures`. Explicitly scoped to the 5 fixed debug cells
    (`DEBUG_CELL_NAMES`), not the full generic per-pin config — that RTL doesn't exist
    on hardware yet.
  - `tools/nemo_ctl/tests/test_link.py`: 27 tests against an in-memory model of
    `link_ctrl.sv`'s own parsing/dispatch rules (`_FakeDevice`/`_FakeTransport`), not
    real hardware — frame encode/decode, config encode/decode, every `Link` method,
    NACK handling, timeouts, and a protocol-level mirror of the live-frequency-change
    exit criterion. Added `pyserial>=3.5` to `tools/requirements.txt`.
  - `tools/nemo_ctl/cli.py`: added a `link` subcommand group (`status`/`run`/`stop`/
    `apply`/`set-clock`/`read-captures`), each with `--help` text cross-referencing
    `docs/USER_MANUAL.md` §6, per the standing CLI-text rule. `set-clock` reuses
    `units.quantize_clock()` (same quantization the wizard uses) so a requested
    frequency/duty gets the same achieved-value-and-error treatment everywhere in this
    tool. 3 new subprocess tests in `tools/nemo_ctl/tests/test_cli.py` (help text,
    missing `--port`, clean failure on an unreachable port).
  - `docs/USER_MANUAL.md`: new §6 "Phase 5 — the runtime link" (scope note, the PMOD
    blocker, simulate-first instructions, the `nemo_ctl.cli link` walkthrough), updated
    §0 status table, §1 setup note for `pyserial`, §7 troubleshooting rows, §8 quick
    reference rows. Old §6/§7 renumbered to §7/§8.
  - `docs/controller_spec.md`: marked §7 (register map draft) and §8 (link protocol
    draft) superseded by `docs/link_register_map.md`, with the real implementation's
    two deltas from the original sketch noted (LOAD_MODE is an explicit NACK, not
    silently ignored; read requests still carry LEN dummy payload bytes).
  - `docs/experiments/EXP-02_phase5_link_bringup.md`: full hardware procedure and exit-
    criterion checklist, results table left PENDING (same pattern as EXP-01).
- Hardware setup: **none — no Vivado, no board access in this environment.** Everything
  above is `pytest`/Icarus Verilog only.
- Results:
  - **[simulated]**: `scripts/run_phase5_link_sim.sh` — `uart_tb` 12/12,
    `link_ctrl_tb` 22/22, `phase5_link_top_tb` 7/7 (including the live frequency-change
    exit criterion, period 20 ticks -> 40 ticks while RUNning).
  - **[not hardware]**: `python3 -m pytest tools/nemo_ctl/tests`: 102/102 (72 pre-
    existing + 27 new `test_link.py` + 3 new `test_cli.py`).
  - **[measured on board]**: none yet — see `docs/experiments/EXP-02...md` §4, PENDING.
- Problems / fixes:
  - `phase5_link_top_tb.sv` compile errors (declaration-before-use for a reset signal
    used before its `logic` declaration; a task's 3rd argument silently inheriting the
    `output` direction from the preceding `output int period_ticks` argument because it
    had no explicit `input` keyword — classic SV ANSI-port-list gotcha, not an Icarus
    bug) — fixed by reordering the declaration and adding the explicit `input` keyword.
  - Real testbench timing bug, not an RTL bug: the mock PC's `pc_send_frame` task
    returned right after queuing the checksum byte's send pulse, before that byte
    actually finished transmitting (~8680 cycles at 100 MHz/115200 baud) — margins
    after RUN/APPLY/STOP were far too short, and worse, the first fix attempt (a blind
    extra-cycle margin added unconditionally inside `pc_send_frame`) broke the READ_REG
    test by eating the response's own leading byte(s) during that margin, before
    `pc_wait_for_response` ever started listening. Fixed by having `pc_send_frame` wait
    for the transport to actually go idle (no blind margin baked in), and adding an
    explicit one-byte-period margin only at call sites checking a side effect of a
    response-less command (RUN/STOP/APPLY), not before commands that get a response.
- Decisions:
  - Proceeding into Phase 5 despite Phase 4's own hardware exit criterion
    (`docs/experiments/EXP-01...md`) being unmeasured — explicit, informed call by
    Rahaf, deviating from `generic_controller_prompt.md`'s normal "wait for approval
    between phases" rule. Both Phase 4 and Phase 5 hardware bring-up remain open.
  - `send_config()`/the debug-harness helpers in `link.py` are scoped to exactly the 5
    fixed cells `phase5_link_top.sv` wires up, not the full generic per-pin
    `config.py`/`nemo_config.yaml` model — that generic RTL hasn't been built. Keeping
    this explicit (via `DEBUG_CELL_NAMES` and docstrings) rather than pretending the
    Python API already covers the real chip's pin set.
  - Per Rahaf's standing rule, **Phase 5 is not marked done** — RTL/software are ready
    and simulated, but the PMOD UART adapter's pin/voltage is still unconfirmed
    (blocking even wiring it up), and nobody has run `docs/experiments/EXP-02...md` on
    real hardware yet.
- Next steps: confirm the PMOD bank voltage for the USB-UART adapter against the actual
  ZedBoard reference manual (the single blocker on starting EXP-02 at all), update
  `fpga/constraints/phase5_link_top.xdc` with the real `rxd`/`txd` pin assignment, then
  run EXP-01 and EXP-02 on real hardware. Still open from earlier: the real "4. User
  manual" section of `generic_controller_prompt.md` was never delivered by Rahaf despite
  being asked three times — still needed if that reorganization is wanted.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 0 of `generic_controller_prompt.md` — a spec for one generic, user-configurable
  controller that replaces the hard-coded bring-up designs, so the user picks what every
  chip input does per mode without editing HDL. No code this phase.
- Done:
  - Located the brief's source files (none of the stated paths were trusted blindly; verified
    each): `docs/reference/nemo_chip/Blocks.xlsx` sheet "Blocks Interface - Digital";
    `docs/reference/nemo_chip/IO_pinout.xlsx` sheet "IO-Pins-Dima" (the brief's named
    `IO_pinout2.xlsx` does not exist as a filename in the repo — same content lives in
    `IO_pinout.xlsx`, per that folder's own README); `docs/session1/NEMO chip SIPO, PISO and
    Y-Flash modes explained.pdf` (read in full, 13 pages); `fpga/reference/dima_blocks/`
    (`sipo.sv`, `sipo_wrapper.sv`, `piso.sv`, read in full).
  - Installed `openpyxl` and `pypdf` locally (not present in the environment) to read the
    `.xlsx`/`.pdf` sources programmatically rather than by eye.
  - Wrote `docs/controller_spec.md`: reconciled 26-signal pin table (22 in + 4 out, matching
    the session1 explainer's own count), config schema shape, FPGA register-map sketch, a
    link-protocol frame draft, a link-options comparison with a recommendation, a rough
    (unmeasured) resource estimate, and every disagreement found between the source sheets.
- Hardware setup: none this session (spec only).
- Results: none measured. The 26-signal list, the register-map sizes and the resource
  estimate are **[simulated/estimated]** at best — nothing synthesized or run yet.
- Problems / fixes: n/a (research/documentation session).
- Decisions: none made — this phase produces a spec for approval, not a decision. One
  recommendation given (link option (a), USB-UART on a PMOD) but explicitly left open
  pending the user's sign-off per the task brief's phase-gate rule.
- Disagreements / open questions found while cross-checking the sheets (full detail in
  `docs/controller_spec.md` §2 and §5):
  - Neither "Blocks Interface - Digital" nor "IO-Pins-Dima" alone lists all 22 inputs + 4
    outputs the session1 explainer says exist; the correct 26 only appears by taking the
    union of both sheets.
  - `rst_sipo`: absent from "Blocks Interface - Digital" (pad 39 there is "Unused"); pin 37
    in "IO-Pins-Dima"'s numbered list. The task brief's own note says pad 39 — neither number
    is confirmed as the true physical pad.
  - DFT-per-ADC select width disagrees: 4 bits (`s0-3_dft`) on "Blocks Interface - Digital"
    vs. 2 bits (`s0-1_dft` only) on "IO-Pins-Dima" — neither cleanly selects the 8-way DFT
    mux the brief describes.
  - `s0_p/s1_p/s2_p` (newer sheet) vs. `s0/s1/s2` (older sheet) — same signals, renamed; the
    explainer confirms this is a known rename, not two different pins.
  - `Pinout_TO1`, `Pinout`, `Pinout_Dima` describe an unrelated, SPI-based digital interface
    (`SCLK/SDI/SDO/CS/DATA<0:7>/...`) that matches none of the current chip's RTL signal
    names — treated as describing an earlier/different chip generation, not this one.
  - The unnumbered `PISO_WR` row and the "stand-alone test structure" pins are both flagged
    as possibly not applicable to the current chip (one looks like a leftover from the SPI
    scheme above; the other is explicitly stated in session1 to be off the latest pad ring).
  - No chip-pin → FMC LA_P assignment exists anywhere in the repo yet — every signal's FMC
    pin is TBD in `docs/controller_spec.md` §3, to be decided in Phase 1/4, constrained to
    the 32 verified LA_P pins (only pair 0 has a hardware-confirmed loopback so far, per
    `docs/pin_verification.md`).
  - PMOD bank voltage (needed to judge link option (a)) is not documented anywhere in this
    repo; not assumed in the spec, flagged as TBD pending a check against the actual
    ZedBoard reference manual.
- Next steps: get the spec in `docs/controller_spec.md` approved (or redirected) and the
  link choice made — these are the Phase 0 exit criteria in `generic_controller_prompt.md`.
  Phase 1 (config format + Python core) does not start before that.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 0 exit + Phase 1 of `generic_controller_prompt.md` — config format + Python
  core, no hardware. Phase 0 spec approved; link choice = option (a), USB-UART on a PMOD
  (PMOD voltage still needs checking against the real ZedBoard manual before any wiring).
- Done:
  - Updated `docs/controller_spec.md` §9/§11 to record the approval and link decision.
  - Added `tools/nemo_ctl/`, a Python package (no FPGA code):
    - `gen_pin_db.py` — regenerates `data/pin_db.yaml` straight from
      `docs/reference/nemo_chip/Blocks.xlsx` / `IO_pinout.xlsx`, applying the Phase 0
      reconciliation (both sheets' disagreeing pad numbers kept side by side, not
      resolved); raises if a workbook changes in a way the reconciliation doesn't expect.
    - `pins.py`, `types.py`, `groups.py`, `dft_helper.py` — pin database, the 7 setting
      types, BUS pin groupings (`s_p`, `b_dft`, `s_dft`), and the DFT "pick ADC k, signal
      X" helper (kept explicitly `confirmed=False`, per spec §4).
    - `units.py` — ns/us/ms/Hz/kHz/MHz/% <-> 100 MHz-tick integers, always reporting
      achieved value + error (checked against the brief's own worked example: 3 MHz ->
      N=33 -> 3.0303 MHz, +1.0%, matches exactly).
    - `config.py` — loads/saves `config/nemo_config.yaml`.
    - `validate.py` — the four required checks: allowed types per pin, safe limits
      (generic 10 MHz warn / 50 MHz hard clock ceiling + any pin-specific limit), SERIAL
      must reference a configured CLOCK pin, no pin configured twice.
    - `timing.py` — per-mode timing summary table.
    - `preview.py` — WaveDrom JSON waveform preview per mode.
    - `excel_io.py` — Excel import/export, one sheet per mode, same columns as the YAML,
      plus a blank template generator.
  - Added `config/nemo_config.yaml`: the example from the brief, filled out for
    INFERENCE (Clock Generator, Array with Muxes, DSA, SIPO, PISO, DFT - All), with READ
    and WRITE left empty (TBD, per spec §1/§6). `pin_map` present with every chip pin ->
    `null` (TBD, nothing assigned yet, per spec §3).
  - Added `tools/nemo_ctl/tests/` (pytest, 55 tests) covering every module above,
    including a regression test that re-running `gen_pin_db.py` against the live
    workbooks reproduces the checked-in `pin_db.yaml` exactly.
  - Fixed a real bug this testing turned up: `validate.py`'s clock hard-limit check
    compared against the *achieved* frequency, but `quantize_clock` already clamps
    `period_ticks` to a minimum of 2 ticks, so achieved frequency can never exceed 50 MHz
    on the 100 MHz timebase — the check was dead code. Fixed to check the *requested*
    frequency instead, so asking for e.g. 60 MHz is now correctly flagged as an error
    (not silently clamped to 50 MHz with no warning).
  - Fixed an unrelated pre-existing bug found while editing `.gitignore`: it had
    unresolved git merge-conflict markers (`<<<<<<<`/`=======`/`>>>>>>>`) committed on
    `main` since `0b26dd4` ("merge: fold Rahaf's initial upload into the repo layout") —
    cleaned up by merging both halves' content, deduplicated, and added the new Python
    tooling ignores (`__pycache__/`, `.pytest_cache/`, etc.).
  - Added `pytest.ini` (repo root, points at `tools/nemo_ctl/tests`) and
    `tools/requirements.txt` (openpyxl, pyyaml, pytest).
- Hardware setup: none — Phase 1 is explicitly software-only.
- Results: **[simulated/software only]**. `python3 -m pytest` from the repo root: 55
  passed, 0 failed. The example INFERENCE config validates with 4 warnings (all TBD/
  UNCONFIRMED items already flagged in the spec, zero errors) and produces a correct
  timing table and WaveDrom preview — this is the Phase 1 exit criterion.
- Problems / fixes: the two bugs above (dead hard-limit check; broken `.gitignore`).
- Decisions: Excel export/import round-trips through a flat, fixed column set
  (`Block, Pin, Type` + every param key any type uses) rather than a different column
  set per type, so "same columns" (brief's own requirement) holds exactly across modes
  and sheets.
- Next steps: Phase 2, the interactive CLI wizard — needs my approval/redirection first
  per the brief's phase-gate rule, same as Phase 0 -> Phase 1 was.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 2 of `generic_controller_prompt.md` — interactive CLI wizard. Approved to
  proceed straight after Phase 1 in the same session, no redirection needed.
- Done:
  - Added `tools/nemo_ctl/wizard.py`: a headless engine (functions take `ask`/`tell`
    callables instead of calling `input()`/`print()` directly, so the whole flow is
    scriptable in tests — not just usable from a real terminal). Implements the brief's
    flow exactly: pick mode -> each block -> each input pin, current setting + a menu
    built from exactly the types `pin_db.yaml` allows for that pin (no dead options like
    offering "pulse" on a CLOCK-only pin). Per-block extras: copy the block from another
    mode, reset it to defaults (clear it), and — for the two DFT groups — a "DFT helper
    (pick ADC + signal)" shortcut that resolves both `b_dft` and `s_dft` from one pick
    (still `confirmed=False`, per spec §4) with a "materialize" step so later overriding
    just one of the two groups doesn't silently lose the other's value.
  - BUS groups (`s_p`, `b_dft`, `s_dft`) are walked once, not once per member pin, with
    a "set individually" escape hatch back to the raw per-pin menu — raw bit control
    stays possible, per the brief's own requirement.
  - Added `tools/nemo_ctl/cli.py`: the one file that actually calls `input()`/`print()`.
    `python3 -m nemo_ctl.cli wizard --mode INFERENCE` (plus `validate`, `preview`,
    `export-excel`, `import-excel`, `gen-template`). Saves back to
    `config/nemo_config.yaml` by default; `--excel` also exports afterward.
  - Added `tools/nemo_ctl/tests/test_wizard.py` (7 tests: full scripted INFERENCE build,
    copy-block, reset-to-defaults, invalid-choice retry, DFT-helper-then-override, bad
    width error) and `tests/test_cli.py` (6 tests driving the actual `python3 -m
    nemo_ctl.cli` subprocess, including the wizard over piped stdin — not just the
    in-process engine).
  - Exercised the exit criterion for real: scripted the full INFERENCE profile (every
    block, every pin) through both the headless engine and the piped-stdin CLI, checked
    it validates with zero errors (same TBD/UNCONFIRMED warnings as Phase 1, nothing
    new), and round-trips through Excel export/import byte-for-byte on the parsed config.
- Hardware setup: none — Phase 2 is software-only, same as Phase 1.
- Results: **[simulated/software only]**. `python3 -m pytest`: 68 passed, 0 failed
  (55 from Phase 1 + 13 new). Manual full-profile run via both the engine and the real
  CLI (piped stdin) confirmed clean.
- Problems / fixes: found and fixed a real round-trip bug in `config.py`'s
  `config_to_dict` while building the scripted full-build test — a block that ends up
  with zero settings (e.g. `dft per ADC` once the DFT helper absorbs it into `DFT - All`)
  wrote no rows to its Excel sheet, so re-importing lost that block key entirely even
  though every other consumer (`iter_settings`, `validate_config`, `timing`, `preview`)
  already treats "block absent" and "block present but empty" identically. Fixed by
  dropping empty blocks consistently in `config_to_dict`, so both directions agree.
  (First caught this with a manual script, not a test — then wrote
  `test_full_inference_build_validates_and_round_trips_through_excel` to pin it down.)
- Decisions: the DFT helper writes/reads a single `dft_select` entry under the
  `DFT - All` block (matching the brief's own schema example) rather than two separate
  per-group entries; overriding one of the two groups it covers "materializes" both
  into explicit `b_dft`/`s_dft` BUS settings first, so the un-overridden group's value
  survives instead of disappearing along with `dft_select`.
- Next steps: Phase 3 (RTL cells + testbenches) is the first phase that touches
  `fpga/src`/`fpga/tb` — needs my approval/redirection first, same phase-gate rule as
  before. Everything through Phase 2 remains software/config only, no hardware claims.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 3 of `generic_controller_prompt.md` — RTL cells + testbenches:
  `sig_cell.sv`, `cap_cell.sv`, `run_ctrl.sv`, each with a self-checking testbench
  covering the brief's required edge cases (N=2, odd N, width=1 tick, delay=0, cycles=1,
  config change while running), plus a utilization estimate for the 26 cells.
- Done:
  - No Vivado/license-server in this environment, so installed **Icarus Verilog**
    (`iverilog`/`vvp` 13.0) to actually run the testbenches, and **yosys** (0.69) to get a
    real synthesized utilization number instead of a hand count — both via
    `/opt/homebrew/bin/brew` (this machine also has a broken Intel Homebrew at
    `/usr/local` whose bundled compiler can't build anything; the arm64 one works via
    prebuilt bottles, no compile needed). Documented in CLAUDE.md §4 as secondary,
    local-only tools — Vivado remains the real target toolchain, nothing here produces a
    bitstream.
  - Added `fpga/src/sig_cell.sv`: one generic cell per driven chip pin, modes
    LOW/HIGH/PULSE/CLOCK/SERIAL. **Deliberately did not give it a 6th "BUS" hardware
    mode** — a BUS setting (`tools/nemo_ctl/groups.py`) is already decomposed into plain
    LOW/HIGH per pin by the Python tool before it reaches a register, so a BUS mode in
    hardware would be a dead, untestable state identical to LOW/HIGH. Flagged per
    CLAUDE.md §2's "if you find a concrete reason to deviate, explain first" — explained
    in the module's header comment. Also dropped a separate "polarity" config field: the
    pin_db/wizard layer already resolves polarity into `idle_level` (confirmed against
    `tools/nemo_ctl/data/pin_db.yaml`'s own `rst_sipo`/`rst_piso` entries), so carrying
    both would just be redundant, conflicting information reaching the same cell.
  - Added `fpga/src/cap_cell.sv`: one generic capture cell per chip output pin, modes
    LEVEL/EDGE_COUNT/PERIOD/SERIAL. Assumes `sync_in` is already 2-FF-synchronized
    upstream (per the architecture diagram), consistent with CLAUDE.md §8.
  - Added `fpga/src/run_ctrl.sv`: global RUN/STOP + one-cycle APPLY strobe, with 2-FF
    synchronizers + edge detection on all three command inputs (CLAUDE.md §8: every
    asynchronous input gets a 2-FF synchronizer) so a command held high for many cycles
    (e.g. a switch, not a one-shot pulse) still only fires once.
  - Added self-checking testbenches: `fpga/tb/sig_cell_tb.sv` (24 checks),
    `fpga/tb/cap_cell_tb.sv` (13 checks), `fpga/tb/run_ctrl_tb.sv` (9 checks), and
    `fpga/tb/integration_tb.sv` (16 checks, a small sanity wiring of one `sig_cell` CLOCK
    through `run_ctrl` into one `cap_cell` PERIOD measurement — not required by the
    brief's module list on its own, but cheap given the unit tests already existed, and
    it catches wiring mistakes before Phase 4's real top level). 62 checks total, all
    passing. Added `scripts/run_phase3_sims.sh` to re-run all four plus the yosys
    estimate in one command.
  - Added `fpga/tb/utilization_estimate_top.sv`: synthesis-only scaffolding (not built by
    `scripts/create_project.tcl`, not simulated) that instantiates the real 26 cells —
    `TICK_W=20` (realistic for this project: the largest delay in
    `config/nemo_config.yaml` today is 150 us = 15,000 ticks = 14 bits; 20 gives headroom
    to ~10.5 ms), `SERIAL_W=136` for `sipo_in`, `CAP_W=168` for `piso_out`, 1 for every
    other pin (which never uses SERIAL/serial-capture) — and ran it through
    `yosys synth_xilinx -family xc7`.
- Hardware setup: none — still simulation/synthesis-estimate only, no FPGA involved.
- Results: **[simulated]** — `scripts/run_phase3_sims.sh`: 62/62 checks pass across the
  four testbenches (real Icarus Verilog 13.0 runs, not claimed without execution).
  **Utilization — [measured, real synthesis output, not estimated]** (yosys 0.69,
  `synth_xilinx -family xc7`, not Vivado — no P&R, no timing closure):
  FF (`FDCE`+`FDPE`) 4,923 / 106,400 (4.6%); LUT (`LUT2`-`LUT6`) 6,449 / 53,200 (12.1%);
  1,254 `CARRY4` chains; yosys "Estimated LCs" 5,244 / 53,200 (9.9%). Higher LUT usage
  than Phase 0's hand-counted guess (~3%), mainly from the two wide shift registers
  (136+168=304 bits) and the `CARRY4`-chain comparators every 20-bit tick counter needs —
  still comfortably inside the chip's budget. `docs/controller_spec.md` §10/§10a updated
  (old guess kept for history, marked superseded).
- Problems / fixes (several real bugs found via the testbenches, not just test-script
  typos — each confirmed with a VCD/print trace before deciding which side the bug was
  really on):
  - **Testbench race** (the big one): driving `apply`/`run`/`shift_strobe` right after
    `@(posedge clk)` races the DUT's own `always_ff` evaluating that identical edge — both
    are separate processes woken by the same event with no defined relative order.
    Icarus resolved it by running the testbench's post-wait code before the DUT saw the
    edge, making every config appear to load one full cycle early and costing 7 failing
    checks the first run. Fixed by driving all stimulus at `@(negedge clk)` instead (a
    distinct event, half a cycle from either neighbouring posedge — removes the ambiguity
    entirely), and documented as a comment in every testbench's `tick()`/drive tasks so
    it isn't rediscovered next phase.
  - **Second, related race**: reading DUT outputs with a bare `@(posedge clk)` (no delay)
    sees their pre-edge (one-cycle-stale) value, since those outputs update via
    nonblocking assignment in the NBA region, which runs strictly after the Active region
    that resumes right after the wait. Edge-counting checks (counting occurrences over
    many ticks) didn't care and passed even with this bug present, which is exactly why
    it wasn't caught until point-in-time checks (exact pulse timing, SERIAL bit values)
    started failing. Fixed by adding a 1ns settle (`#1`) after every `@(posedge clk)` used
    for sampling.
  - `sig_cell.sv`'s combinational `next_pin_out` block originally used `unique case` plus
    a same-block override `if` statement after the case; Icarus 13.0 only partially
    supports that pattern for this toolchain (own "sorry" warnings nearby). Simplified to
    a single `if (!run) ... else case (...)` with no `unique` qualifier and no
    post-case override — cleaner regardless of the tool quirk, and the actual fix (the
    bug above was the real cause; this was a secondary, real but not symptom-causing
    cleanup done at the same time).
  - PULSE test expectation bug (not an RTL bug): `delay=20` was assumed to mean the
    action starts on tick 20; the RTL actually (and sensibly) starts it on tick 21 — 20
    full idle ticks (1..20), action on the 21st — consistent with how delay=0 already
    behaved (0 idle ticks, action immediately on tick 1). Fixed the test's expectation,
    not the RTL.
  - `cap_cell.sv` SERIAL capture alignment: confirmed (not a bug) that `msb_first`
    (shifts left, new bit at LSB) and `!msb_first` (shifts right, new bit at the top)
    land a *partial* capture (`cfg_bits < CAP_W`) in different halves of the register —
    bottom `[cfg_bits-1:0]` for msb_first, top `[CAP_W-1:CAP_W-cfg_bits]` for !msb_first.
    Only matters when `CAP_W != cfg_bits`; documented in the module header so Phase 4
    sizes `CAP_W` to the real frame width (as `utilization_estimate_top.sv` already does)
    and never has to care.
- Decisions: `sig_cell` gets no hardware BUS mode and no separate polarity field (both
  explained above); atomic `apply` resets every internal counter/shift-register to zero
  (not just the config fields), so a config change while running cleanly restarts the
  cell's sequence under the new config rather than trying to splice old phase into new
  timing. `TICK_W` widened from the Phase 0 register-map sketch's implied 16 bits to a
  parameter (20 used for the utilization estimate, 32 as the modules' own default) —
  Phase 0 §7 called that sketch "sizing only," so this is a refinement, not a conflict.
- Next steps: Phase 4 (top level with compile-time config, hardware bring-up on the
  verified loopback pairs) — needs my approval/redirection first, same phase-gate rule.
  This is the first phase that touches real hardware; everything through Phase 3 is
  simulation/synthesis-estimate only.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 4 of `generic_controller_prompt.md` — top level with compile-time config,
  hardware bring-up on the verified/pin-mapped loopback pairs. **Important limitation
  hit immediately: this phase's own exit criterion needs [measured on board] results,
  which needs Vivado (not installed/licensed here) and physical access to the ZedBoard,
  jumper wires, and a multimeter/scope (none available in this environment).** Did
  everything achievable without those — the compile-time config generator, the top-level
  RTL + XDC, and pre-validating all of it in simulation — and stopped at the hardware
  boundary rather than fabricate a "ran fine" result. `docs/experiments/EXP-01_*.md` is
  the handoff: fully written setup/procedure, results table marked PENDING.
- Done:
  - Added `config/phase4_loopback_test.yaml` + `tools/nemo_ctl/gen_svh.py` ->
    `fpga/src/gen/nemo_cfg_pkg.svh`: one `sig_cell`+`cap_cell` pair per signal TYPE
    (CLOCK/PULSE/SERIAL/LOW/HIGH), each on one loopback pair (0-4) from
    `docs/pin_verification.md` — **not** the real chip config (`config/nemo_config.yaml`,
    whose `pin_map` is still all `null`; there's no chip-pin -> FMC assignment to build a
    real top level from yet). This matches the brief's own suggested Phase 4 activity:
    "hardware test of every signal type on the verified loopback pairs." CLOCK uses
    100 Hz (the already-proven `fmc_clock_loopback_slow` approach, read 0.899 V on the
    multimeter previously); PULSE/SERIAL use human/multimeter/scope-scale timing (500 ms,
    10 Hz) deliberately, so a person — or an oscilloscope — can actually observe them.
  - Added `fpga/src/phase4_loopback_top.sv` + `fpga/constraints/phase4_loopback_top.xdc`:
    `run_ctrl` + 5 driven test pairs + 5 capture pairs + an internal helper clock (not
    tied to any pin) generating the SERIAL pair's shift/capture strobe. `sw[4]`=RUN,
    `sw[2:0]`=which pair's status shows on the LEDs, no reset button (internal power-on
    counter + a single auto-APPLY, since this is compile-time config with no link). XDC
    reuses the exact same confirmed pin assignments as every earlier bring-up design
    (clk/sw/led/fmc_pins all copied from `fmc_clock_loopback.xdc`, which agrees with the
    other 4 XDC files already in the repo).
  - Added `fpga/tb/phase4_loopback_top_tb.sv` (21 checks) + `scripts/run_phase4_sim.sh`:
    pre-validates the whole top level with Icarus Verilog before it ever touches Vivado.
    Models the 5 **external** jumper wires directly (shorting `fmc_pins[i]` to
    `fmc_pins[i+16]`) since the real jumpers don't exist in simulation — the DUT itself
    never connects them, same as on the real board. Deliberately checks only what's
    reachable in a short simulated window (first edges, immediate levels, the LED mux,
    the fault latch staying clear) since the real timings (500 ms pulse, 10 Hz strobe)
    are far too slow to simulate to completion in reasonable wall-clock time — a
    documented scope limit, not a shortcut: the brief's real validation is the hardware
    step this testbench cannot replace.
  - Fixed `scripts/create_project.tcl`: it only globbed `fpga/src/*.v`/`*.sv`, which would
    have silently missed the generated `fpga/src/gen/*.svh` package — added that glob.
  - Added a note to `docs/pin_verification.md` pointing at EXP-01 as pending additional
    coverage for pairs 1-4, without touching that table's own PASS/FAIL columns (those
    are T2-T4 results specifically, not this).
- Hardware setup: **none — this is the limitation, see above.**
- Results: **[simulated]** only. `scripts/run_phase3_sims.sh`: 69/69 (sig_cell grew to 28
  checks, +4 for a new `SERIAL_W=1`/width-edge-case regression; cap_cell grew to 16, +3
  for the matching `CAP_W=1` case). `scripts/run_phase4_sim.sh`: 21/21.
  `python3 -m pytest`: 72/72 (added `gen_svh` tests). **No [measured on board] result
  exists for this phase** — `docs/experiments/EXP-01_phase4_generic_controller_bringup.md`
  §4 is a template, not a result.
- Problems / fixes (several real bugs, each confirmed with a minimal repro before
  deciding which side the bug was on — same discipline as Phase 3):
  - **Real RTL bug in `sig_cell.sv`/`cap_cell.sv`**: `{shift_reg[SERIAL_W-2:0], ...}` /
    `{capture_reg[CAP_W-2:0], ...}` becomes an invalid `[-1:0]` part-select whenever
    `SERIAL_W`/`CAP_W` == 1 — exactly the width every non-SERIAL pin in
    `phase4_loopback_top.sv` actually uses (cheapest possible shift register for a mode a
    cell will never run). Neither Phase 3 unit testbench happened to exercise width==1,
    so this sat undetected until the first real multi-cell top level. Fixed with a
    `generate if (WIDTH > 1) / else` producing a same-named "next value" signal, used by
    the main `always_ff` either way (`sig_cell`: the width==1 "next" value is an unused
    placeholder, since `bits_exhausted` gates off any shift beyond the first bit anyway;
    `cap_cell`: it's `sync_in` directly, since capturing straight into the one bit a
    1-bit register has *is* the meaningful behavior there, not a placeholder). Added a
    dedicated `SERIAL_W=1`/`CAP_W=1` regression test to each Phase 3 testbench.
  - **Icarus-specific width-resolution bug, not an RTL bug**: wildcard-importing a
    package (`import nemo_cfg_pkg::*;`) and then using an imported localparam as a module
    port connection got silently truncated to 1 bit before zero-padding back — confirmed
    with a minimal repro completely outside this project's files, and confirmed it
    disappears with explicit `pkg::NAME` scoping instead of a wildcard import
    (`$bits()` on the same identifier correctly reports 32 either way, so this is purely
    about the *connection*, not the declaration). This one mattered: it would have fed
    `cfg_param_a`/`cfg_param_b` almost-always-wrong values (e.g. the 100 Hz clock's
    1,000,000-tick period truncated to its LSB, 0, then zero-extended) if shipped as a
    "just a warning, probably fine" — rewrote every reference in
    `phase4_loopback_top.sv` to explicit `nemo_cfg_pkg::` scoping.
  - **Generator bug** (`tools/nemo_ctl/gen_svh.py`): MSB-first SERIAL data was emitted
    right-justified (`0x00A5` for an 8-bit `0xA5` in a 16-bit field), but `sig_cell.sv`'s
    own header comment already specifies MSB-first data must be left-justified (shifts
    left from the top bit) — confirmed against the already-passing `sig_cell_tb.sv`,
    which used the correct left-justified form. Fixed to shift left by
    `(DATA_FIELD_W - bits)` for `msb_first`, left as-is for `!msb_first` (already
    naturally right-justified, which is what shifting right from the bottom needs).
  - **Design fix, not exactly a bug**: the SERIAL pair's helper clock drove its
    `shift_strobe` from `rising_edge`, which fires immediately on the very first tick of
    RUN (the idle -> first-high-phase transition) — shifting the first bit away before it
    was ever presented. Switched to `falling_edge` (can't occur before at least a
    half-period has elapsed), matching the real SIPO/PISO convention noted in
    `docs/session1` (data changes on `clk_sipo`'s falling edge, not rising).
- Decisions: built the bring-up top level against a dedicated test config
  (`config/phase4_loopback_test.yaml`), not the real chip config — there is no FMC pin
  assignment for the real 26 signals yet (`config/nemo_config.yaml`'s `pin_map` is still
  all `null`), so generating a "real" top level now would mean inventing pin assignments.
  This dedicated-config approach still satisfies the brief's own Phase 4 activity
  ("hardware test of every signal type on the verified loopback pairs") without that.
- Next steps: **run EXP-01 on real hardware** — needs Vivado + a physical ZedBoard with
  VADJ on 1.8 V, 5 jumper wires per the experiment doc, and a multimeter/scope. I cannot
  do this part; it needs you (or Yazan) to actually run it and fill in EXP-01 §4. Once
  that's done [measured on board], Phase 5 (runtime link) is next and needs
  approval/redirection first, same phase-gate rule as every prior phase.

---

## 2026-10-16, Rahaf, branch feature/rahaf-user-manual
- Goal: new standing requirement from Rahaf, on top of `generic_controller_prompt.md`:
  maintain `docs/USER_MANUAL.md` for a lab user who did not build the system; catch up
  the manual for every completed phase before continuing the current one; a phase isn't
  "done" until its manual section is written AND Rahaf has followed it successfully;
  every CLI command gets `--help` text matching the manual; the wizard shows a one-line
  hint per field.
- **Process note, not a technical result, but worth recording**: the actual trigger for
  this was Rahaf asking me to replace `docs/prompts/generic_controller.md` with "the new
  version I'm giving you," adding a "4. User manual" section. That new version was never
  actually delivered — three separate pastes, each a different file already in this
  repo (an old/different draft found in `~/Downloads`, then `docs/controller_spec.md`,
  then the current `generic_controller_prompt.md` itself, byte-for-byte). I asked each
  time rather than guess at a spec I didn't have. When Rahaf said "continue" without
  providing it a fourth time, I went ahead using my own judgment for the manual's
  structure instead of continuing to block on it — flagged clearly in the manual's own
  header so it's not mistaken for an agreed outline. `docs/prompts/generic_controller.md`
  itself was never created; the task file is still `generic_controller_prompt.md` at the
  repo root, unchanged.
- Done:
  - Added `docs/USER_MANUAL.md`: status table (which phases are usable today), setup,
    then one section per completed phase (Phase 1 config/validate/preview/Excel, Phase 2
    wizard walkthrough, Phase 3 RTL simulation, Phase 4 build+simulate with a clear "the
    hardware step is not done yet" callout matching `docs/WORKLOG.md`'s own Phase 4
    entry), a troubleshooting table, and a file-location quick reference.
  - Verified every command block in the manual by actually running it (not written from
    memory and assumed correct) — `validate`, `preview` (both formats), `export-excel`,
    `import-excel`, `gen-template`, a full scripted `wizard` session, both
    `scripts/run_phase3_sims.sh` and `scripts/run_phase4_sim.sh`, and the two
    troubleshooting-table claims that were checkable (`ModuleNotFoundError` without `-m`;
    `validate` printing nothing on a clean config). Fixed one real mistake this caught in
    my own first draft of the verification script (wrong block order for a scripted
    wizard run) before it ever reached the manual itself.
  - Added `--help` text to every `nemo_ctl.cli` subcommand (`wizard`, `validate`,
    `preview`, `export-excel`, `import-excel`, `gen-template`): a `description` matching
    the manual's wording (cross-referenced by section number) for each, an `epilog` with
    a runnable example where it mattered (`wizard`'s overwrite warning + safe-copy
    example), and `help=` text on every individual argument that was missing one.
  - Added a one-line hint to every wizard sub-prompt that was missing one or had only a
    bare unit example (`pulse`'s delay/polarity, `clock`'s cycles/delay, `serial`'s data/
    bits/msb_first) — what the field controls, not just an example value.
- Hardware setup: none — this is documentation + CLI/wizard text only.
- Results: **[not applicable — no hardware, no simulation changed]**. `python3 -m
  pytest`: 72/72 still passing (prompt-text changes don't affect the tests, which drive
  by scripted answers, not by matching prompt wording).
- Problems / fixes:
  - Real (small) bug found while adding hints, not just wording: the SERIAL type's
    "which edge does data change on" prompt hardcoded the literal text `clk_sipo`
    regardless of which clock pin the user had actually just named in the previous
    answer. Fixed to interpolate the real `clock` variable.
  - Not a bug, but worth recording: `wizard.py`'s existing prompts already had decent
    inline hints (e.g. `width (e.g. 1us, 100ns):`) before this session; the gap was
    mainly missing units on the two `delay` prompts and no "what does this control"
    framing, not a total absence of hints.
- Decisions: per Rahaf's new rule, **this phase (user manual, Phases 0-4 catch-up) is not
  marked done** — it needs Rahaf to actually follow the manual successfully, which I
  cannot do on their behalf. Everything above is a draft for that review, same spirit as
  `docs/experiments/EXP-01`'s results table being left PENDING rather than filled in from
  simulation.
- Next steps: Rahaf follows `docs/USER_MANUAL.md` end to end (§2-§5) and reports back
  anything confusing, wrong, or missing. Once that's clean, maintaining this file going
  forward means: every future phase gets its manual section written before being called
  done, matching the new standing rule. Separately, still open from the prior entry:
  `docs/prompts/generic_controller.md` / the "4. User manual" section of the task brief
  itself is still needed from Rahaf if that reorganization is still wanted.

---

## 2026-10-12, Yazan, branch feature/repo-setup
- Goal: put the project under git so both team members (and their Claude sessions) share one source of truth.
- Done:
  - Imported bring-up sources from the lab PC folder `FPGA_PROJECT_YR` (14/09 meeting): 7 HDL files to `fpga/src/`, 5 XDC files to `fpga/constraints/`. No code changes.
  - Added `CLAUDE.md` (shared context), `.gitignore` (Vivado output), `README.md`, `scripts/create_project.tcl` (rebuilds a project per top module into `build/`).
  - Added docs: this log, `pin_verification.md`, `decisions.md`, `issues.md`, the LaTeX bring-up log, the measurement PDFs and the FMC pin-mapping spreadsheet.
  - Added the project spec + presentation + NEMO tracking sheet (`docs/project/`), the 14/09 meeting material (`docs/meetings/2026-09-14/`), the Y-Flash papers (`docs/reference/papers/`), and Dima's SIPO/PISO code as reference only (`fpga/reference/dima_blocks/`, not built).
  - Cross-checked: all 5 XDC files assign the same package pins to the 32 FMC LA_P ports.
- Hardware setup: none this session.
- Results: none new. Earlier results are summarized in `pin_verification.md`.
- Problems / fixes: CLAUDE.md listed `PINS layout.xdc`; the actual file is `PINS_layout.xdc` (fixed). `single_pin_tester.v` was missing from the file table (added).
- Merge with Rahaf's first push (`22ce4bb`, raw copy of the lab folder on `main`): every file was byte-identical to the organized copy here (`PINS_layout.xdc` differed only in line endings), so the raw copies were removed. Dropped generated `IO_DEFINE.xpr`, `fmc_loopback_test.dcp` and the Office lock file `~$NEMO_Tracking.xlsx`. Rahaf's top-level `NEMO_Tracking.xlsx` differs from the lab-PC copy, so both are kept: `docs/project/NEMO_Tracking.xlsx` (lab PC, 14/09) and `docs/project/NEMO_Tracking_rahaf_2026-10-12.xlsx`. **Resolved 2026-10-13: kept Rahaf's version.** Merged both `.gitignore` files.
- Decisions: Vivado project files are not committed; they are regenerated by `scripts/create_project.tcl`.
- Next steps: `create_project.tcl` has not been run in Vivado yet; run it once and fix any issues. Then verify pairs 1-15 (CLAUDE.md section 7).

## 2026-10-13, Yazan, branch main
- Goal: add NEMO chip reference workbooks.
- Done: added `docs/reference/nemo_chip/Blocks.xlsx` and `IO_pinout.xlsx` (from `IO_pinout(2).xlsx`) with a README describing the sheets. No code changes.
- Results: none.
- Next steps: use the Pinout sheets to plan the chip-pin to FMC LA-pin mapping for the SIPO/PISO and phase signals.
- Moved Rahaf's `session1/` (SIPO/PISO/Y-Flash explanation PDF + 6 diagrams) to `docs/session1/` to match the repo layout; contents unchanged. CLAUDE.md layout and SIPO/PISO task now point there.
- Deleted the old lab-PC `NEMO_Tracking.xlsx`; Rahaf's version renamed to `docs/project/NEMO_Tracking.xlsx` (the only copy now; the old one remains in git history).
