# ==============================================================================
# generic_fmc_io_top.xdc
# ZedBoard + FMC: 32x LA_P pins as bidirectional fmc_pins[31:0] (VADJ = 1.8V)
# Same physical pins as PINS_layout.xdc's out_pins[*], renamed for the
# generic bidirectional tester. Port order matches
# "pin_mapping (FMC-FPGA).xlsx".
# ==============================================================================

set_property PACKAGE_PIN Y9 [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports {clk}]

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

# FMC VADJ = 1.8V for all 32 pins
set_property IOSTANDARD LVCMOS18 [get_ports {fmc_pins[*]}]
