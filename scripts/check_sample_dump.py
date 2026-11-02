"""Check sample_loopback_top_tb's two records (written with +dump_a / +dump_b) on the PC side:
samples.py decodes them, seqwaves.py builds the expected waves of
config/phase7_seq_loopback.yaml at the testbench's x1e-4 and compares.
  record A (step 1 start, jumpers in): every pin must pass
  record B (step 2 start, clk_in jumper pulled): clk_in must fail, every other pin pass
Run by scripts/run_sample_sim.sh (from tools/):  python ../scripts/check_sample_dump.py A B
"""
import sys
from pathlib import Path

import yaml

from nemo_ctl.samples import LOOPBACK_PINS, Record, make_setup
from nemo_ctl.seqwaves import check_record, scale_steps
from nemo_ctl.verify import VerifyResult, format_text

SEQ = Path(__file__).resolve().parents[1] / "config" / "phase7_seq_loopback.yaml"
STEPS = scale_steps(yaml.safe_load(SEQ.read_text())["steps"], 1e-4)


def load(path, step):
    lines = Path(path).read_text().split()
    div, n, tidx, tcount = (int(x) for x in lines[:4])
    words = tuple(int(x, 16) for x in lines[4:4 + n])
    setup = make_setup({"pins": list(LOOPBACK_PINS), "period": f"{div * 10}ns", "samples": n,
                        "pre": tidx, "trigger": "ext", "step": step}, list(LOOPBACK_PINS), n_bits=16)
    return setup, Record(words, tidx, tcount)


ok = True
for name, path, step, want_fail in (("A", sys.argv[1], 1, set()), ("B", sys.argv[2], 2, {"clk_in"})):
    setup, rec = load(path, step)
    rows = check_record(STEPS, setup, rec)
    print(f"record {name}: {setup.summary()}")
    for line in format_text(VerifyResult(mode=name, runs=[rows]))[:-1]:
        print("  " + line)
    failed = {r.pin for r in rows if r.ok is False}
    judged = [r for r in rows if r.ok is not None]
    good = failed == want_fail and len(judged) == len(LOOPBACK_PINS)
    print(f"  -> {'as expected' if good else 'NOT as expected'}: fails {sorted(failed) or 'none'}"
          f" (expected {sorted(want_fail) or 'none'})")
    ok &= good
print("check_sample_dump: " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
