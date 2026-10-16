# ==============================================================================
# phase5_link_top.xdc
#
# clk/sw/led/fmc_pins reuse the exact same physical pins already verified in
# phase4_loopback_top.xdc (all prior XDC files in this repo agree on these).
# sw is now only [2:0] (phase4's sw[3:0] pair-select and sw[4] drive-enable
# are gone -- Phase 5 config comes from the link instead), so sw[3]/sw[4]'s
# PACKAGE_PIN lines are simply dropped here, not reassigned.
#
# rxd/txd (the USB-UART link to the PC) are DELIBERATELY left unconstrained.
# Per docs/USER_MANUAL.md's Phase 5 section and phase5_link_top.sv's header
# comment: which ZedBoard PMOD header carries the UART bridge, and whether
# that bank is 3V3 or VADJ(1V8), was never confirmed back in Phase 0. Do not
# invent a PACKAGE_PIN/IOSTANDARD here -- add them once that's checked against
# the ZedBoard reference manual, then re-run EXP-02.
# ==============================================================================

set_property PACKAGE_PIN Y9 [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports {clk}]

# On-board switches SW0-SW2 (only 3 used this phase)
set_property PACKAGE_PIN F22 [get_ports {sw[0]}]
set_property PACKAGE_PIN G22 [get_ports {sw[1]}]
set_property PACKAGE_PIN H22 [get_ports {sw[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sw[*]}]

# On-board LEDs LD0-LD7
set_property PACKAGE_PIN T22 [get_ports {led[0]}]
set_property PACKAGE_PIN T21 [get_ports {led[1]}]
set_property PACKAGE_PIN U22 [get_ports {led[2]}]
set_property PACKAGE_PIN U21 [get_ports {led[3]}]
set_property PACKAGE_PIN V22 [get_ports {led[4]}]
set_property PACKAGE_PIN W22 [get_ports {led[5]}]
set_property PACKAGE_PIN U19 [get_ports {led[6]}]
set_property PACKAGE_PIN U14 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# 32 FMC LA_P pins (bidirectional); only 0-4 (out) / 16-20 (in) are driven or
# read by this design -- see phase5_link_top.sv's header comment for the
# jumper wiring needed (J3-0<->J3-16, J3-1<->J2-17, ... J3-4<->J2-20), same
# as Phase 4.
# Pins 0-7 (LA00_P to LA07_P)
set_property PACKAGE_PIN M19 [get_ports {fmc_pins[0]}]
set_property PACKAGE_PIN N19 [get_ports {fmc_pins[1]}]
set_property PACKAGE_PIN P17 [get_ports {fmc_pins[2]}]
set_property PACKAGE_PIN N22 [get_ports {fmc_pins[3]}]
set_property PACKAGE_PIN M21 [get_ports {fmc_pins[4]}]
set_property PACKAGE_PIN J18 [get_ports {fmc_pins[5]}]
set_property PACKAGE_PIN L21 [get_ports {fmc_pins[6]}]
set_property PACKAGE_PIN T16 [get_ports {fmc_pins[7]}]

# Pins 8-15 (LA08_P to LA15_P)
set_property PACKAGE_PIN J21 [get_ports {fmc_pins[8]}]
set_property PACKAGE_PIN R20 [get_ports {fmc_pins[9]}]
set_property PACKAGE_PIN R19 [get_ports {fmc_pins[10]}]
set_property PACKAGE_PIN N17 [get_ports {fmc_pins[11]}]
set_property PACKAGE_PIN P20 [get_ports {fmc_pins[12]}]
set_property PACKAGE_PIN L17 [get_ports {fmc_pins[13]}]
set_property PACKAGE_PIN K19 [get_ports {fmc_pins[14]}]
set_property PACKAGE_PIN J16 [get_ports {fmc_pins[15]}]

# Pins 16-23 (LA16_P to LA23_P)
set_property PACKAGE_PIN J20 [get_ports {fmc_pins[16]}]
set_property PACKAGE_PIN B19 [get_ports {fmc_pins[17]}]
set_property PACKAGE_PIN D20 [get_ports {fmc_pins[18]}]
set_property PACKAGE_PIN G15 [get_ports {fmc_pins[19]}]
set_property PACKAGE_PIN G20 [get_ports {fmc_pins[20]}]
set_property PACKAGE_PIN E19 [get_ports {fmc_pins[21]}]
set_property PACKAGE_PIN G19 [get_ports {fmc_pins[22]}]
set_property PACKAGE_PIN E15 [get_ports {fmc_pins[23]}]

# Pins 24-31 (LA24_P to LA31_P)
set_property PACKAGE_PIN A18 [get_ports {fmc_pins[24]}]
set_property PACKAGE_PIN D22 [get_ports {fmc_pins[25]}]
set_property PACKAGE_PIN F18 [get_ports {fmc_pins[26]}]
set_property PACKAGE_PIN E21 [get_ports {fmc_pins[27]}]
set_property PACKAGE_PIN A16 [get_ports {fmc_pins[28]}]
set_property PACKAGE_PIN C17 [get_ports {fmc_pins[29]}]
set_property PACKAGE_PIN C15 [get_ports {fmc_pins[30]}]
set_property PACKAGE_PIN B16 [get_ports {fmc_pins[31]}]

set_property IOSTANDARD LVCMOS18 [get_ports {fmc_pins[*]}]

# rxd/txd: INTENTIONALLY NOT CONSTRAINED -- see header note above.
