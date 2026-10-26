"""Run the sequence already loaded on chip_top / vchip_top N times and compare a cap cell's
capture with an expected value each time (EXP-08: 300 runs in ~8 s).

    cd tools && python -m nemo_ctl.cli seq load ../config/chip_sim_test.yaml --jtag
    PYTHONPATH=. python ../scripts/repeat_seq.py 300 piso_out 0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6

Prints one line per run (PASS, or the number of wrong bits and the first one).
"""
import sys

from nemo_ctl.jtag import open_jtag
from nemo_ctl.link import SeqLink
from nemo_ctl.sequence import chip_target

n, cell, want = int(sys.argv[1]), sys.argv[2], int(sys.argv[3], 0)
sl = open_jtag(link_cls=SeqLink, target=chip_target())
width = sl.target.cap_cells[sl.target.cap_index(cell)].cap_w
w = format(want, f"0{width}b")
fails = 0
try:
    for i in range(n):
        sl.start()
        r = sl.wait(5)
        got = sl.read_capture(cell)
        g = format(got, f"0{width}b")
        bad = [k for k in range(width) if g[k] != w[k]]
        fails += bool(bad) or not r.done or r.fault
        print(f"run {i + 1}: done={r.done} fault={r.fault} 0x{got:0{(width + 3) // 4}X} "
              + (f"wrong bits {len(bad)}, first {bad[0]}" if bad else "PASS"))
finally:
    sl.close()
print(f"{n - fails} / {n} PASS")
