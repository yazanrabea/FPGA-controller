# ==============================================================================
# jtag_echo_test.tcl  (xsdb, NOT Vivado)
# JTAG link step J1 (docs/experiments/EXP-05_*.md): talks to jtag_echo_top's
# BSCANE2 USER4 data register (JTAG_CHAIN env var to change) over the J17 PROG cable.
#
# Usage (board programmed with jtag_echo_top, from the repo root):
#   xsdb scripts/jtag_echo_test.tcl            (lab PC: C:\Xilinx\Vivado\2022.1\bin\xsdb.bat)
#   xsdb scripts/jtag_echo_test.tcl 5A         (last scan pattern 0x5A.. instead of the default C1)
#   xsdb scripts/jtag_echo_test.tcl C1 2000    (2000 scans in the speed/error test)
#
# 1. Echo check (USER$CHAIN): each scan must return the bitwise inverse of the previous scan's data
#    (jtag_echo_core.sv). Compared in xsdb's own hex encoding both ways, so the result
#    doesn't depend on which end of the hex string is bit 0.
# 2. Speed: N scans of DR_BITS bits, one `run` each (how a polling link would use it),
#    then the same N scans batched into one sequence.
# Prints PASS/FAIL lines and "ALL TESTS PASSED" / "N CHECK(S) FAILED".
# ==============================================================================

set DR_BITS 1024
# 7-series USER instruction codes (6-bit IR). jtag_echo_top uses USER4: hw_server scans
# USER1 by itself and overwrote our register there (EXP-05).
array set USER_IR {1 02 2 03 3 22 4 23}
set CHAIN   [expr {[info exists env(JTAG_CHAIN)] ? $env(JTAG_CHAIN) : 4}]
set USER1   $USER_IR($CHAIN)   ;# kept under this name: the IR code for the chain in use
set N_SPEED [expr {$argc > 1 ? [lindex $argv 1] : 100}]   ;# 2nd arg: scans in the speed test
set led_byte [expr {$argc > 0 ? [lindex $argv 0] : "C1"}]

set fails 0
set checks 0
proc check {cond msg} {
    global fails checks
    incr checks
    if {$cond} { puts "  PASS: $msg" } else { puts "  FAIL: $msg"; incr fails }
}

# hex string of DR_BITS/4 digits from a 2-digit seed pattern, and its bitwise inverse
proc pattern {seed} {
    global DR_BITS
    return [string repeat $seed [expr {$DR_BITS / 8}]]
}
proc invert_hex {h} {
    set out ""
    foreach c [split [string toupper $h] ""] {
        append out [format %X [expr {(~[scan $c %x]) & 0xF}]]
    }
    return $out
}

# one USER1 DR scan: shift `hex` in, return what came out (xsdb hex encoding)
proc dr_scan {hex} {
    global DR_BITS USER1
    set seq [jtag sequence]
    $seq irshift -state IDLE -hex 6 $USER1
    # end in IDLE, not DRUPDATE: jtag_echo_core registers Update-DR on the TCK edge that
    # LEAVES Update-DR, so the scan must go on to Run-Test/Idle
    $seq drshift -state IDLE -capture -hex $DR_BITS $hex
    set r [$seq run -hex]
    $seq delete
    return [string toupper [string trim $r]]
}

connect
puts "JTAG targets:"
puts [jtag targets]
jtag targets -set -filter {name =~ "xc7z*"}
puts "Selected: [jtag targets -filter {name =~ "xc7z*"}]"
puts "JTAG frequency: [jtag frequency] Hz, USER$CHAIN (IR 0x$USER1)"
# Exclusive access to the cable for the whole test. Without it ~2.5% of scans read back all
# ones (hw_server's own JTAG traffic gets in between; 12/500 at 15 MHz, 14/500 at 5 MHz, so
# not signal integrity); with it 0/500 and faster (EXP-05, docs/issues.md).
jtag lock

puts "\n== 1. echo check ($DR_BITS-bit USER1 scans) =="
set a [pattern DE]
set b [pattern 35]
set c [pattern 0F]
set r0 [dr_scan $a]
puts "  first scan returned: [string range $r0 0 15]... (~0 = all F if this is the first scan since programming)"
set r1 [dr_scan $b]
check [expr {$r1 eq [invert_hex $a]}] "scan 2 returns ~(scan 1 data)"
set r2 [dr_scan $c]
check [expr {$r2 eq [invert_hex $b]}] "scan 3 returns ~(scan 2 data)"
set r3 [dr_scan $a]
check [expr {$r3 eq [invert_hex $c]}] "scan 4 returns ~(scan 3 data)"
if {[string length $r1] != $DR_BITS / 4} {
    puts "  NOTE: returned [string length $r1] hex digits, expected [expr {$DR_BITS / 4}]"
}

puts "\n== 2. speed =="
set t0 [clock milliseconds]
set prev $a
set ok 1
for {set i 0} {$i < $N_SPEED} {incr i} {
    set d [pattern [format %02X [expr {$i & 0xFF}]]]
    set r [dr_scan $d]
    if {$r ne [invert_hex $prev]} { set ok 0 }
    set prev $d
}
set t1 [clock milliseconds]
set ms [expr {$t1 - $t0}]
check $ok "$N_SPEED separate scans all echoed correctly"
set bytes [expr {$N_SPEED * $DR_BITS / 8}]
puts [format "  separate runs: %d scans x %d bytes in %d ms = %.1f ms/scan, %.0f bytes/s" \
      $N_SPEED [expr {$DR_BITS / 8}] $ms [expr {double($ms) / $N_SPEED}] [expr {$ms > 0 ? 1000.0 * $bytes / $ms : 0}]]

set seq [jtag sequence]
$seq irshift -state IDLE -hex 6 $USER1
for {set i 0} {$i < $N_SPEED} {incr i} {
    $seq drshift -state IDLE -hex $DR_BITS [pattern 3C]
}
set t0 [clock milliseconds]
$seq run
set t1 [clock milliseconds]
$seq delete
set ms [expr {$t1 - $t0}]
puts [format "  one batched run: %d scans in %d ms = %.0f bytes/s" \
      $N_SPEED $ms [expr {$ms > 0 ? 1000.0 * $bytes / $ms : 0}]]

# leave a known byte on the LEDs: the board shows last[7:0], so this also tells us
# which end of xsdb's hex string is bit 0
dr_scan [pattern $led_byte]
puts "\nLast scan sent pattern $led_byte$led_byte...: LD0-LD7 now show last\[7:0\]."

puts ""
if {$fails == 0} { puts "ALL TESTS PASSED ($checks checks)" } else { puts "$fails CHECK(S) FAILED out of $checks" }
jtag unlock
disconnect
