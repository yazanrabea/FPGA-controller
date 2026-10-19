# ==============================================================================
# program_board.tcl
# Programs the ZedBoard's XC7Z020 over JTAG with the bitstream that
# create_project.tcl built for <top_module>.
#
# Usage (from the repo root, board powered, PROG micro-USB J17 connected):
#   vivado -mode batch -source scripts/program_board.tcl -tclargs <top_module>
#   e.g. -tclargs phase4_loopback_top
#
# Before running: check the J18 (VADJ) jumper is on 1V8 and set the switches the
# experiment's procedure asks for (e.g. EXP-01: sw[4:0] = 00000, RUN off).
# ==============================================================================

set repo [file normalize [file join [file dirname [info script]] ..]]

if {$argc < 1} {
    puts "ERROR: give the top module name, e.g. -tclargs phase4_loopback_top"
    exit 1
}
set top [lindex $argv 0]
set bit [file join $repo build $top $top.runs impl_1 $top.bit]
if {![file exists $bit]} {
    puts "ERROR: no bitstream at $bit -- build it first:"
    puts "  vivado -mode batch -source scripts/create_project.tcl -tclargs $top build"
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "ERROR: no JTAG target found -- is the board powered and PROG (J17) connected?"
    exit 1
}
open_hw_target [lindex $targets 0]

# The ZedBoard chain has the ARM DAP and the xc7z020 PL; program the PL.
set dev [lindex [get_hw_devices -quiet xc7z020*] 0]
if {$dev eq ""} {
    puts "ERROR: no xc7z020 on the JTAG chain (found: [get_hw_devices -quiet])"
    exit 1
}
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -quiet $dev
puts "PROGRAMMED: $dev with [file tail $bit] (DONE=[get_property -quiet REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev])"
close_hw_target
