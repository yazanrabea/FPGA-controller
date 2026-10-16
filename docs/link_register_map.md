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
stride wide enough for the widest cell instead of a uniform 24 B) is Phase 6/8 work, once
real chip pins are assigned.

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
