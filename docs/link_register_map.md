# Phase 5 link register map (concrete, from the real Phase 3/4 RTL)

Supersedes the Phase 0 sketch in `docs/controller_spec.md` §7, which was sized before
`sig_cell.sv`/`cap_cell.sv` existed and explicitly said so ("a sketch for sizing only").
This map backs `fpga/src/phase5_link_top.sv` — the same 5 test pairs from Phase 4
(`test_clock`, `test_pulse`, `test_serial`, `test_low`, `test_high`, indices 0-4), now
driven by this register file instead of compile-time constants. **Not** the real 26-pin
chip map — there's still no chip-pin -> FMC assignment (see `docs/controller_spec.md`
§3), same scoping decision Phase 4 made.

All registers are little-endian, byte-addressed, 16-bit address space (only a small part
used). `R`/`W`/`R` `W` = read-only / write-only-effect / both.

## Global (0x0000-0x000F)

| Addr | Name | Width | Access | Meaning |
|---|---|---|---|---|
| 0x0000 | `SCRATCH` | 1 B | R/W | No hardware effect — for the "echo" sanity test (write, read back, confirm match) before anything functional is tried. |
| 0x0001 | `RUN_CTRL` | 1 B | R/W | Write 1 -> pulses `run_ctrl`'s `run_set` for one cycle. Write 0 -> pulses `run_clear`. Read -> current `run` level (0/1). |
| 0x0002 | `APPLY_CTRL` | 1 B | W | Write anything -> pulses `apply_cmd` for one cycle. Reads back 0. |
| 0x0003 | `STATUS` | 1 B | R | bit0 = `run` level. bits1-7 reserved (0) — no fault bits defined yet, nothing in `run_ctrl`/`sig_cell`/`cap_cell` produces one. |
| 0x0004-0x000F | reserved | 12 B | — | — |

## sig_cell shadow config, 0x0010-0x0087 (5 cells x 24 B)

Cell `k`'s base address = `0x0010 + 24*k`. `k`: 0=test_clock, 1=test_pulse,
2=test_serial, 3=test_low, 4=test_high (same order as `phase4_loopback_top.sv`).

| Offset | Name | Width | Access | Maps to (`sig_cell.sv` port) |
|---|---|---|---|---|
| +0x00 | `CTRL` | 1 B | R/W | bits[2:0] = `cfg_type` (LOW=0,HIGH=1,PULSE=2,CLOCK=3,SERIAL=4); bit3 = `cfg_idle_level`; bit4 = `cfg_msb_first`; bits5-7 reserved |
| +0x01 | `DELAY` | 4 B | R/W | `cfg_delay` |
| +0x05 | `PARAM_A` | 4 B | R/W | `cfg_param_a` |
| +0x09 | `PARAM_B` | 4 B | R/W | `cfg_param_b` |
| +0x0D | `CYCLES` | 4 B | R/W | `cfg_cycles` |
| +0x11 | `DATA` | 2 B | R/W | `cfg_data` (truncated to 16 bits — see limitation below) |
| +0x13 | `BITS` | 4 B | R/W | `cfg_bits` |
| +0x17 | reserved | 1 B | — | — |

**Known limitation, flagged not hidden**: `DATA` is fixed at 16 bits here because that's
what `phase5_link_top.sv`'s `test_serial` cell actually needs (`SERIAL_W=16`, same as
Phase 4). A real chip deployment needs `sipo_in` at `SERIAL_W=136` (17 bytes) — this
register layout does not support that yet. Widening `DATA` (and picking a per-cell
stride wide enough for the widest cell instead of a uniform 24 B) is Phase 7 round 2 work
("link v2": also adds the step table, see `docs/USER_MANUAL.md` §8), not built yet.

## cap_cell shadow config + status/results, 0x0100-0x0177 (5 cells x 24 B)

Cell `k`'s base address = `0x0100 + 24*k`, same `k` ordering (0=cap_clock ... 4=cap_high).
`CAPTURE_BASE = 0x0100` — `READ_CAPTURE` frames (see link protocol below) address this
region with a 0-based offset instead of the full global address, so the Python client
doesn't need to know it.

| Offset | Name | Width | Access | Maps to (`cap_cell.sv` port) |
|---|---|---|---|---|
| +0x00 | `CTRL` | 1 B | R/W | bits[1:0] = `cfg_mode` (LEVEL=0,EDGE_COUNT=1,PERIOD=2,SERIAL=3); bit2 = `cfg_msb_first`; bits3-7 reserved |
| +0x01 | `BITS` | 4 B | R/W | `cfg_bits` |
| +0x05 | `STATUS_FLAGS` | 1 B | R | bit0 = `level_out`; bit1 = `period_valid` (1-cycle pulse — likely read as 0 unless you're lucky with timing, present for completeness); bit2 = `done` (same caveat); bits3-7 reserved |
| +0x06 | `EDGE_COUNT` | 4 B | R | `edge_count` |
| +0x0A | `PERIOD_TICKS` | 4 B | R | `period_ticks` |
| +0x0E | `HIGH_TICKS` | 4 B | R | `high_ticks` |
| +0x12 | `CAPTURE_REG` | 2 B | R | `capture_reg` (truncated to 16 bits, same limitation as sig_cell's `DATA`) |
| +0x14-0x17 | reserved | 4 B | — | — |

## Link protocol (frame, same shape as `docs/controller_spec.md` §8, now with real semantics)

| Field | Size | Notes |
|---|---|---|
| `SOF` | 1 B | `0xAA` |
| `CMD` | 1 B | see below |
| `ADDR` | 2 B, LE | register address (`WRITE_REG`/`READ_REG`) or offset within the capture region (`READ_CAPTURE`); ignored by `APPLY`/`RUN`/`STOP`/`STATUS` |
| `LEN` | 1 B | payload length in bytes (`WRITE_REG`: bytes that follow; `READ_REG`/`READ_CAPTURE`: bytes requested in the response) |
| `DATA` | `LEN` B | payload; absent for `APPLY`/`RUN`/`STOP`/`STATUS` requests |
| `CHECKSUM` | 1 B | XOR of `CMD..DATA` |

| CMD | Value | Request payload | Response |
|---|---|---|---|
| `WRITE_REG` | 0x01 | `ADDR`, `LEN`, `DATA` | none (fire-and-forget) |
| `READ_REG` | 0x02 | `ADDR`, `LEN` | a frame, `CMD=READ_REG`, `DATA`=the `LEN` bytes read from `ADDR` |
| `LOAD_MODE` | 0x03 | — | **not implemented this phase** — `link_ctrl.sv` NACKs it (see decision below), not silently ignored |
| `APPLY` | 0x04 | none | none |
| `RUN` | 0x05 | none | none |
| `STOP` | 0x06 | none | none |
| `STATUS` | 0x07 | none | a frame, `CMD=STATUS`, 1-byte `DATA` = the global `STATUS` register |
| `READ_CAPTURE` | 0x08 | `ADDR`=offset into the capture region, `LEN` | a frame, `CMD=READ_CAPTURE`, `DATA`=the `LEN` bytes read from `CAPTURE_BASE+ADDR` |
| `NACK` (response only) | 0xFF | — | sent back for a bad checksum or an unimplemented `CMD` (currently just `LOAD_MODE`) |

**Decision: `LOAD_MODE` is not implemented on the FPGA side this phase.** The brief's
Python API (`send_config(mode)`) doesn't need it — sending a whole mode is just one
`WRITE_REG` per configured pin followed by one `APPLY`, all of which the generic
`WRITE_REG`/`APPLY` commands already do. `LOAD_MODE` stays reserved in the `CMD` enum
(so the frame shape matches `docs/controller_spec.md` §8 exactly) in case a future phase
wants the FPGA to hold multiple mode presets and switch between them without resending
every register — that's not what this phase needs, so it's not built. Sending it gets an
explicit `NACK`, not a silent no-op, so a caller can tell the difference between "did
nothing because unimplemented" and "did nothing because it succeeded trivially."

"Echo" (the first item in the brief's test order: "echo -> register write/readback ->
full config") is not a separate `CMD` — it's `WRITE_REG` to `SCRATCH` (0x0000) followed by
`READ_REG` from the same address, confirming the whole UART+framing path round-trips a
byte correctly before anything that actually touches a cell is tried.

## Frame engine changes in Phase 7 round 2 (apply to both maps)

The parser/responder now lives in `fpga/src/link_frame.sv`, shared by `link_ctrl.sv`
(the Phase 5 map above) and `phase7_link_top.sv` (v2 below). The frame format and the
commands are unchanged. What changed:
- A WRITE_REG takes effect **LEN+4 ticks** after its checksum byte (one byte per tick on
  the internal register bus) instead of 2. That can't be seen over UART.
- A 16-byte input FIFO sits in front of the parser, so bytes arriving while a write or
  read is still being handled are kept, not dropped. If it overflows, a sticky
  `rx_overflow` is set (v2: STATUS bit 7).
- LEN larger than the top's buffer (128 B for Phase 5, 255 B for v2) gets a NACK.
- A read is answered only once the previous response has been fully sent.

## v2: `phase7_link_top.sv` (Phase 7 round 2, step sequencer)

Same frames and commands, a different register map. The FPGA holds a **step table**
(up to 16 steps) and runs it with `seq_engine.sv`; the Python client is
`tools/nemo_ctl/link.py` `SeqLink`, the command line `python -m nemo_ctl.cli seq ...`.
Cells: the same 5 loopback pairs as Phase 4/7 (target `PHASE7_LOOPBACK` in
`tools/nemo_ctl/sequence.py`). The UART pins are still unconstrained (EXP-02).

| CMD | Meaning in v2 |
|---|---|
| `RUN` (0x05) | START the loaded sequence (ignored while one is running) |
| `STOP` (0x06) | ABORT it: RUN low, pins back to step 0 |
| `APPLY` (0x04) | re-apply step 0 with RUN low (the idle state), e.g. right after loading a table |
| `STATUS` (0x07) | returns the STATUS byte below |
| `WRITE_REG` / `READ_REG` / `READ_CAPTURE` | as before, on the map below |
| `LOAD_MODE` (0x03) | NACK (still reserved) |

| Addr | Name | Access | Meaning |
|---|---|---|---|
| 0x0000 | `SCRATCH` | R/W | echo test |
| 0x0003 | `STATUS` | R; W clears bit 6 | bit0 run, bit1 busy, bit2 done, bit3 fault (a wait timed out), bit4 aborted, bit5 late (a step boundary waited for the prefetch, so it wasn't tick-exact), bit6 table_rejected (a table or N_STEPS write arrived while busy and was ignored), bit7 rx_overflow (sticky until reset). Bits 2-5 stay set until the next START |
| 0x0004 | `STEP` | R | current step |
| 0x0005 | `LAST_STEP` | R | step the last run ended on (done / fault / abort) |
| 0x0006 | `N_STEPS` | R/W | steps in the table, 1..16 (0 -> 1, >16 -> 16); write refused while busy |
| 0x0100 + 16·k | cap cell k results | R | `READ_CAPTURE` offset 16·k (stride = 13 + widest capture, rounded up to 8: 16 here). +0 flags (bit0 level, bit2 done), +1..+4 edge count (LE), +5..+12 reserved (period/high time not wired on this top, read 0), +13.. capture register (LE, 2 bytes here) |
| 0x1000 + 256·k | step k's entry | W only (reads 0) | 148 bytes used of 256, layout below; refused while busy |

**Step entry layout** (single source: `sequence.entry_layout()`, generated into
`fpga/src/gen/phase7_link_pkg.sv`; little-endian):

| Offset | Field |
|---|---|
| 0 | SIG_MASK: bit i = sig cell i re-applied at this step |
| 1 | CAP_MASK: bit i = cap cell i re-armed |
| 2 | COND: 0 after, 1 done, 2 captured, 3 edges, 4 level |
| 3 | COND_CELL |
| 4..7 | COND_ARG (after: ticks; edges: count; level: 0/1) |
| 8..11 | TIMEOUT (ticks; required for wait steps) |
| 12 + per sig cell | CTRL (type[2:0], idle[3], msb_first[4]), DELAY, PARAM_A, PARAM_B, CYCLES, BITS (4 B each), DATA (ceil(SERIAL_W/8) B, already justified the way `sig_cell` expects). 22 B per 1-bit cell, 23 B for `data` (16 bits). Blocks at 12, 34, 56, 79, 101 |
| per cap cell | CTRL (mode[1:0], msb_first[2]), BITS (4 B). Blocks at 123, 128, 133, 138, 143 |

Every step's entry holds every cell's config *in effect* during that step; only the
masked cells are re-applied at the step's start. Step 0 must apply all cells (the
compiler enforces it). One step's entry fits one WRITE_REG frame (148 ≤ 255).

**Timing over the link:** while step k runs, `seq_bank.sv` copies step k+1 out of the
RAM, which takes ~40 ticks (0.4 µs). If step k ends sooner (a fixed step under ~40
ticks, or a wait whose condition is already true), step k+1 starts as soon as the copy
lands and STATUS.late is set. `python -m nemo_ctl.cli seq load` warns about fixed
steps that are too short; waits can only be caught by the flag.

## v2 sampler: `sample_loopback_top.sv` (verification plan 2026-11-01 Step 3)

`phase7_link_top` with `SAMPLER = 1` (wrapper `sample_loopback_top`, JTAG) adds a
`sample_cell` to the v2 map above; everything else is unchanged. Without it
(`phase7_link_jtag_top`) these addresses read 0, so `INFO` = 0 means "no sampler".
PC side: `link.SeqLink.sampler_info / sampler_setup / sampler_status / read_samples`,
`tools/nemo_ctl/samples.py`, `cli seq sample`.

Each sample is 16 bits: bits 0-4 = the 5 outputs `clk rst data cs en` (LA00-04_P, delayed
by 2 FFs so they line up with the inputs), bits 5-9 = the 5 inputs `clk_in .. en_in`
(LA16-20_P after their 2-FF synchronizer), bits 10-13 = the sequencer's current step
(also through 2 FFs, so the PC sees when each step started, even after a wait step),
bits 14-15 = 0. 4096 samples.

| Addr | Name | Access | Meaning |
|---|---|---|---|
| 0x0020-0x0023 | `S_DIV` | R/W | ticks per sample (0 or 1 = every 10 ns tick) |
| 0x0024-0x0025 | `S_N` | R/W | samples to record, 1..4096 (0 -> 1, more -> 4096) |
| 0x0026-0x0027 | `S_PRE` | R/W | of those, kept from before the trigger (< `S_N`) |
| 0x0028 | `S_TRIG` | R/W | 0 now (first sample), 1 ext (start of step `S_TRIG_STEP`), 2 rise, 3 fall, 4 high, 5 low (on bit `S_TRIG_PIN`, judged between samples) |
| 0x0029 | `S_TRIG_PIN` | R/W | bit 0..15 of the sample for rise / fall / high / low |
| 0x002A | `S_TRIG_STEP` | R/W | step number for ext |
| 0x002B | `S_STATUS` | R | bit0 armed (recording, waiting for the trigger), bit1 triggered, bit2 done |
| 0x002C-0x002D | `S_N_VALID` | R | samples in the record |
| 0x002E-0x002F | `S_TRIG_IDX` | R | index of the trigger sample in the record |
| 0x0030-0x0033 | `S_TRIG_COUNT` | R | samples taken since the sequence started, at the trigger sample |
| 0x0034 | `S_INFO_BITS` | R | 16 (bits per sample) |
| 0x0035 | `S_INFO_DEPTH` | R | 12 (log2 of the buffer: 4096) |
| 0x4000 + 2·i | sample i | R (`READ_REG`) | 2 bytes LE; i = 0 is the oldest sample kept, up to `S_N_VALID` - 1 |

- A config write takes effect at the **next sequence start** (RUN): the record being made
  is never changed. RUN clears the record and arms; the end of the sequence stops it and
  the record stays until the next RUN, so it is read after the run.
- Sample i holds the pins as they were `((S_TRIG_COUNT - S_TRIG_IDX + i) * S_DIV + 1 - 2)`
  ticks after the sequencer's run rose (step 0's APPLY is one tick before that).
  [simulated] word by word in `fpga/tb/sample_loopback_top_tb.sv`.
- Reading: up to 100 samples (200 bytes) per `READ_REG` frame; 4096 samples = 41 frames.
  The block RAM's output goes straight onto the bus, so the 1-tick read latency holds.

## Pad readback: `chip_top.sv` (verification plan Step 2, 2026-11-02)

Read with READ_REG (cmd 0x02); nothing here is writable. `chip_pkg.sv` RB_* (generated by
`gen_svh.py --chip`), `link.py` V2_RB_*, `SeqLink.read_readback()`. Values describe the LAST
run (the window = RUN as the pins saw it, delayed 2 ticks like the synchronizer); cleared
when the next run starts. A bitstream without readback reads 0 at RB_INFO.

| Address | Bytes | What |
|---|---|---|
| 0x0200 + 16 i | 16 | sig cell i (chip_target() order): +0 flags (bit 0 saw 0, bit 1 saw 1, bit 2 end level), +1..4 rising edges, +5..8 last period (ticks, 0 = fewer than 2 rises), +9..12 last high time (ticks, 0 = no complete high pulse), +13..15 0 |
| 0x0360 | 16 | info: +0 cells (22; 0 = no readback), +1 PAD_READBACK (1 = read at the pads, 0 = from the output registers, `vchip_top`), +2..3 SIPO bits sampled, +4 SIPO width (136), +5..8 window length (ticks), rest 0 |
| 0x0380 | 17 | the sipo_in readback frame, little-endian (bit 0 = the last bit sampled); sampled on the readback of clk_sipo's sampling edge |

## Transport: JTAG over J17 (instead of the UART), from 2026-10-22

The frames above are a byte stream; it doesn't matter how the bytes travel. With the JTAG
transport (`docs/decisions.md`; RTL `fpga/src/jtag_link_bridge.sv`, wrapper
`fpga/src/jtag_link_bscan.sv`) they ride inside BSCANE2 **USER4** (IR `0x23`) scans over
the PROG cable, and `link_frame.sv` sees the same `rx_byte`/`tx_byte` ports as with
`uart_rx`/`uart_tx`.

Every scan is exactly **1024 bits = 128 bytes** (short scans misalign: EXP-05). Byte i =
bits [8i+7:8i], shifted LSB first; xsdb `-hex` strings are byte-little-endian.

| Byte | PC -> FPGA (TDI, used at Update) | FPGA -> PC (TDO, loaded at Capture) |
|---|---|---|
| 0, 1 | magic `4A 4C` ("JL") | magic `6A 6C` ("jl") |
| 2 | `n_dn`: down data bytes in this scan, 0..124 | flags: bit0 **ready**, bit1 down overflow (sticky) |
| 3 | 0 | `n_up`: up data bytes offered, 0..120 |
| 4 | down data byte 0 (data in bytes 4..127) | `free`: down FIFO space (256-byte FIFO, saturates at 255) |
| 5 | | accepted-scan counter (wraps at 256) |
| 6, 7 | | 0 |
| 8..127 | | up data (bytes 8..127) |

Rules (the PC transport, step J4, must follow them):
1. **A scan is accepted iff its own reply had `ready` = 1** (and its header is valid). So
   the PC knows from the scan it just did whether the FPGA took it.
2. **Accepted:**
   - the FPGA queues the `n_dn` down bytes;
   - it drops the `n_up` up bytes it offered in that same reply; they're now the PC's.
3. **Not accepted (`ready` = 0):**
   - nothing happened: resend the same down bytes later;
   - ignore the reply's data.
4. **Down credit:** send at most `free - n_dn`, where both come from the last accepted
   scan's reply and its own `n_dn`. Extra bytes are dropped and set the overflow flag.
5. A scan without the `JL` magic (hw_server probing, another tool) is ignored completely.
6. The FPGA needs ~3 us after an accepted scan to prepare the next reply. A scan that comes
   sooner gets `ready` = 0. One scan per xsdb `run` (~1.3 ms) always finds it ready.

Throughput, one scan per `run`: up to 124 bytes down and 120 up per ~1.3 ms, about
95 kB/s each way (EXP-05 measured the raw scan rate).
