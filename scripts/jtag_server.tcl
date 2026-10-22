# ==============================================================================
# jtag_server.tcl  (xsdb, NOT Vivado) -- JTAG link step J4
# Serves full-length BSCANE2 user-register scans to tools/nemo_ctl/jtag.py
# (XsdbScanPort), which starts it:  xsdb scripts/jtag_server.tcl [IR_HEX]
#   IR_HEX: user instruction, default 23 = USER4 (USER1 = 02 is disturbed by
#   hw_server, EXP-05).
#
# Prints "READY <port>" on stdout once it listens on 127.0.0.1:<port> (the OS
# picks the port). Line protocol, one client:
#   S <256 hex>   one DR scan (1024 bits; byte 0 = first hex pair, EXP-05)
#                 -> "<256 hex>" = what came back, or "E <message>"
#   P             -> "OK"   (ping)
#   Q             -> "BYE", then unlock, disconnect and exit
# Holds `jtag lock` the whole time, so nothing else scans the board meanwhile.
# ==============================================================================

set DR_BITS 1024
set IR [expr {$argc > 0 ? [lindex $argv 0] : "23"}]

proc dr_scan {hex} {
    global DR_BITS IR
    set seq [jtag sequence]
    $seq irshift -state IDLE -hex 6 $IR
    # end in IDLE, not DRUPDATE: the bridge registers Update-DR on the TCK edge
    # that leaves it (jtag_echo_core.sv / jtag_link_bridge.sv)
    $seq drshift -state IDLE -capture -hex $DR_BITS $hex
    set r [$seq run -hex]
    $seq delete
    return [string toupper [string trim $r]]
}

proc quit {} {
    catch {jtag unlock}
    catch {disconnect}
    exit 0
}

proc handle {chan} {
    global DR_BITS
    if {[gets $chan line] < 0} {
        if {[eof $chan]} { close $chan; quit }
        return
    }
    set cmd [string index $line 0]
    if {$cmd eq "S"} {
        set hex [string trim [string range $line 1 end]]
        if {[string length $hex] != $DR_BITS / 4} {
            puts $chan "E scan must be [expr {$DR_BITS / 4}] hex digits, got [string length $hex]"
        } elseif {[catch {dr_scan $hex} r]} {
            puts $chan "E [string map {"\n" " "} $r]"
        } else {
            puts $chan $r
        }
    } elseif {$cmd eq "P"} {
        puts $chan "OK"
    } elseif {$cmd eq "Q"} {
        puts $chan "BYE"
        close $chan
        quit
    } else {
        puts $chan "E unknown command"
    }
}

proc accept {chan addr port} {
    fconfigure $chan -buffering line -translation lf
    fileevent $chan readable [list handle $chan]
}

if {[catch {
    connect
    jtag targets -set -filter {name =~ "xc7z*"}
    jtag lock
} err]} {
    puts "ERROR could not reach the FPGA over JTAG: $err"
    flush stdout
    exit 1
}

set srv [socket -server accept -myaddr 127.0.0.1 0]
puts "READY [lindex [fconfigure $srv -sockname] 2]"
flush stdout
vwait forever
