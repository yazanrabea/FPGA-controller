# Decisions

Each entry: date, decision, reason, rejected options.

## Use J2/J3 headers, not the SMA jacks
- Decision: all FPGA <-> chip signals go through the J2/J3 0.1" headers (P column).
- Reason: the HTG-FMC-SMA-LVDS SMA jacks are wired to transceiver lanes; the XC7Z020 has no GTX transceivers and only 4 of the 38 SMA signals reach the FPGA (clock inputs only).
- Rejected: SMA jacks for GPIO.

## Pair convention for bring-up
- Decision: output pin i = LAi_P, input pin i+16 = LA(i+16)_P, i = 0..15, selected by `sw[3:0]`; `sw[4]` enables/sets drive.
- Reason: lets one jumper wire per pair test the full out -> board -> in path with a self-checking design.

## Low-frequency clock for multimeter checks
- Decision: use `fmc_clock_loopback_slow` (~100 Hz) for multimeter readings.
- Reason: a handheld multimeter cannot average a 1 MHz square wave; readings were unstable.

## Vivado projects are generated, not committed
- Decision: commit only sources, XDC, testbenches, Tcl and docs; rebuild projects with `scripts/create_project.tcl`.
- Reason: generated files are large, machine-specific and cause merge conflicts between two people.
