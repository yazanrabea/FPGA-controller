# Issues and fixes

Format: symptom, suspected cause, fix, confirmation.

## Switch bounce caused false faults in the clock checker
- Symptom: fault latch (LD3) set right after flipping `sw[4]`.
- Cause: asynchronous, bouncing switch input.
- Fix: 2-FF synchronizer on `sw[4]` plus ~20 ms settle window before checking.
- Confirmation: pair 0 runs at 1 MHz with LD3 off [measured on board].

## Fault latch too sensitive / compared against the wrong cycle
- Symptom: single-cycle mismatches latched a fault.
- Cause: the readback passes through a 2-FF input synchronizer, so it lags the driven value by 2 cycles.
- Fix: delay the expected value by 2 cycles; latch a fault only after 16 consecutive mismatches.
- Confirmation: pair 0 passes [measured on board]. Note: a self-check can lie; confirm with an independent instrument.

## Scope readings: low level or ringing
- Symptom: with 50 ohm scope input, 1.8 V reads ~0.7 V; with 1 Mohm input, ringing on edges.
- Cause: 50 ohm input loads the LVCMOS18 pin; 1 Mohm doesn't terminate the jumper-wire line.
- Fix / practice: use 1 Mohm for true levels and accept ringing on jumper wires; 1 MHz looks clean, 100 MHz looks rounded.
- Status: open, revisit with proper probing (ground spring, short leads) during scope/ILA verification.
