"""Run one editor mode on chip_top N times in a row over one JTAG session (EXP-07), so a
scope in Auto / Run mode sees a new run every ~8 ms instead of one 360 µs burst.

    cd tools && PYTHONPATH=. python ../scripts/repeat_mode.py ../config/exp07_test.yaml INFERENCE 7500

7500 INFERENCE runs take about 60 s. The table is loaded once; each run is start + wait.
"""
import sys
import time

from nemo_ctl.config import load_config
from nemo_ctl.jtag import open_jtag
from nemo_ctl.link import SeqLink
from nemo_ctl.mode_seq import mode_table
from nemo_ctl.sequence import chip_target

config_path, mode, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
table, _ = mode_table(load_config(config_path), mode)
sl = open_jtag(link_cls=SeqLink, target=chip_target())
try:
    sl.load(table)
    done = fault = 0
    t0 = time.time()
    for _ in range(n):
        sl.start()
        r = sl.wait(3.0)
        done += bool(r.done)
        fault += bool(r.fault)
    dt = time.time() - t0
    print(f"{n} runs in {dt:.1f} s ({dt / n * 1000:.1f} ms each): done {done}, fault {fault}")
finally:
    sl.close()
