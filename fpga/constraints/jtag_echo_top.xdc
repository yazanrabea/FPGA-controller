## jtag_echo_top -- JTAG link step J1 (docs/experiments/EXP-05_*.md)
## Only the 100 MHz clock and the 8 user LEDs: no FMC pins are driven.
## clk / led lines copied unchanged from phase4_loopback_top.xdc (verified on the board, EXP-01).

## ---- 100 MHz system clock ----
set_property PACKAGE_PIN Y9 [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports {clk}]

## ---- user LEDs LD0-LD7 ----
set_property PACKAGE_PIN T22 [get_ports {led[0]}]
set_property PACKAGE_PIN T21 [get_ports {led[1]}]
set_property PACKAGE_PIN U22 [get_ports {led[2]}]
set_property PACKAGE_PIN U21 [get_ports {led[3]}]
set_property PACKAGE_PIN V22 [get_ports {led[4]}]
set_property PACKAGE_PIN W22 [get_ports {led[5]}]
set_property PACKAGE_PIN U19 [get_ports {led[6]}]
set_property PACKAGE_PIN U14 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

## ---- JTAG TCK from the BSCANE2 primitive ----
## Vivado doesn't create this clock on its own. 30 MHz is the Digilent cable's ceiling, so
## constraining for it covers any hw_server/xsdb JTAG frequency setting. TCK and the system
## clock are unrelated: the only crossing is last[7:0] -> 2-FF sync -> LEDs.
create_clock -name jtag_tck -period 33.333 [get_pins u_bscan/TCK]
set_clock_groups -asynchronous -group [get_clocks sys_clk_pin] -group [get_clocks jtag_tck]
