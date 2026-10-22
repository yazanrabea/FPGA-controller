"""Phase 7.1: step format, validator, compiler, program-verify loop."""
import copy
from pathlib import Path

import pytest
import yaml

from nemo_ctl import gen_svh
from nemo_ctl.sequence import (
    CAP_MODE, COND, MAX_STEPS, PHASE7_LOOPBACK, SIG_TYPE, SeqResult, SequenceError, StepTable,
    compile_steps, load_sequence, program_verify,
)

CONFIG = Path(__file__).resolve().parents[3] / "config" / "phase7_seq_loopback.yaml"
STEPS = yaml.safe_load(CONFIG.read_text())["steps"]


def _steps(edit=None):
    s = copy.deepcopy(STEPS)
    if edit:
        edit(s)
    return s


def test_type_codes_match_the_phase4_generator():
    assert SIG_TYPE == gen_svh.SIG_TYPE
    assert CAP_MODE == gen_svh.CAP_MODE


def test_demo_sequence_compiles():
    t = load_sequence(CONFIG)
    assert [s.name for s in t.steps] == ["idle", "reset", "load", "latch", "confirm", "hold"]
    assert all(t.steps[0].sig_mask) and all(t.steps[0].cap_mask)
    assert t.steps[1].sig_mask == (False, True, False, False, False)
    assert t.steps[4].sig_mask == (False,) * 5 and t.steps[4].cap_mask == (False,) * 5
    assert t.warnings == ()


def test_demo_ticks():
    t = load_sequence(CONFIG)
    load = t.steps[2]
    clk = load.sig[PHASE7_LOOPBACK.sig_index("clk")]
    assert (clk.type, clk.param_a, clk.param_b, clk.cycles, clk.delay) == (3, 25_000_000, 12_500_000, 8, 1_000_000)
    data = load.sig[PHASE7_LOOPBACK.sig_index("data")]
    assert (data.type, data.bits, data.data) == (4, 8, 0xA500)  # MSB-first: left-justified in 16
    assert (load.cond, load.cond_cell, load.timeout) == (COND["captured"], 2, 500_000_000)
    rst = t.steps[1].sig[1]
    assert (rst.type, rst.idle, rst.param_a) == (2, 1, 50_000_000)  # active-low pulse idles high
    assert t.steps[0].sig[1].idle == 1  # HIGH idles high (reset stays inactive when stopped)
    assert t.steps[0].cond_arg == 100_000_000


def test_unlisted_cells_carry_their_config_forward():
    t = load_sequence(CONFIG)
    assert t.steps[3].sig[0] == t.steps[2].sig[0]  # clk not re-applied in 'latch'
    assert t.steps[5].sig == t.steps[4].sig == t.steps[3].sig


def test_time_scale_keeps_structure():
    fast = load_sequence(CONFIG, scale=1e-4)
    slow = load_sequence(CONFIG)
    assert [s.sig_mask for s in fast.steps] == [s.sig_mask for s in slow.steps]
    assert fast.steps[2].sig[0].param_a == 2500
    assert fast.steps[0].cond_arg == 10_000


def test_summary_is_exact_until_the_first_wait():
    lines = load_sequence(CONFIG).summary()
    assert lines[1].startswith("1 reset: t=100000000 ticks")
    assert "after previous wait" in lines[3]
    assert "edges cs_in >= 1" in lines[3]


@pytest.mark.parametrize("edit,msg", [
    (lambda s: s[0]["set"].pop("cs"), "step 0 must set every cell"),
    (lambda s: s[0]["capture"].pop("en_in"), "step 0 must set every cell"),
    (lambda s: s[1]["set"].update(nope={"type": "LOW"}), "unknown sig cell 'nope'"),
    (lambda s: s[2]["until"].pop("timeout"), "needs a 'timeout'"),
    (lambda s: s[1].update(until={"after": "1ns"}), "at least 1 tick"),
    (lambda s: s[1].update(until={"after": "1s", "done": "rst"}), "exactly one of"),
    (lambda s: s[3].update(until={"done": "clk", "timeout": "1s"}), "isn't set in this step"),
    (lambda s: s[3].update(until={"done": "en", "timeout": "1s"}), "never finishes"),
    (lambda s: s[4].update(until={"captured": "data_in", "timeout": "1s"}), "isn't (re)armed"),
    (lambda s: s[4].update(until={"edges": {"cell": "en_in", "count": 1}, "timeout": "1s"}), "EDGE_COUNT mode"),
    (lambda s: s[4].update(until={"level": {"cell": "en_in", "value": 2}, "timeout": "1s"}), "0 or 1"),
    (lambda s: s[2]["set"]["data"].update(bits=17), "bits=17"),
    (lambda s: s[2]["set"]["data"].update(data_edge="rising"), "hard-wired to clk's falling"),
    (lambda s: s[1]["set"].update(rst={"type": "SERIAL", "data": 1, "bits": 1}), "can't do SERIAL"),
    (lambda s: s[2]["set"]["clk"].update(freq="60MHz"), "50 MHz hard limit"),
    (lambda s: s[1]["set"]["rst"].update(width="1ns"), "0 ticks"),
    (lambda s: s.insert(1, dict(s[1])), "duplicate step name"),
    (lambda s: s.extend([{"name": f"x{i}", "until": {"after": "1us"}} for i in range(MAX_STEPS)]), "at most 16"),
])
def test_bad_sequences_are_rejected(edit, msg):
    with pytest.raises(SequenceError, match=msg.replace("(", r"\(").replace(")", r"\)")):
        compile_steps(_steps(edit))


def test_fast_clock_warns_and_unarmed_edge_count_warns():
    def edit(s):
        s[2]["set"]["clk"]["freq"] = "20MHz"
        s[3].pop("capture")
    t = compile_steps(_steps(edit))
    assert any("above 10 MHz" in w for w in t.warnings)
    assert any("isn't re-armed" in w for w in t.warnings)


# ---------------------------------------------------------------- program-verify

class MockCellSequencer:
    """A 'cell' whose read-back value rises by `gain` per pulse tick in the last loaded
    table's 'pulse' step, like a Y-Flash cell nudged by program pulses."""

    def __init__(self, gain=1, fault_at=None):
        self.value, self.gain, self.fault_at, self.runs = 0, gain, fault_at, 0
        self.table: StepTable | None = None

    def load(self, table):
        self.table = table

    def start(self):
        self.runs += 1
        width = self.table.steps[1].sig[PHASE7_LOOPBACK.sig_index("en")].param_a
        self.value += self.gain * width

    def wait(self, timeout_s):
        if self.fault_at == self.runs:
            return SeqResult(done=False, fault=True, step=1)
        return SeqResult(done=True, fault=False, step=1)

    def read_capture(self, cap_cell):
        assert cap_cell == "data_in"
        return self.value


def _pulse_table(i):
    s = _steps()
    s[1] = {"name": "pulse", "set": {"en": {"type": "PULSE", "width": f"{10 * (i + 1)}ns"}},
            "until": {"after": "1us"}}
    return compile_steps(s[:2])


def test_program_verify_stops_at_the_first_pass():
    seq = MockCellSequencer()
    r = program_verify(seq, _pulse_table, "data_in", check=lambda v: v >= 6, max_iters=10)
    assert r.passed and r.iterations == 3 and r.history == [1, 3, 6]  # widths 1, 2, 3 ticks


def test_program_verify_gives_up_after_max_iters():
    r = program_verify(MockCellSequencer(), _pulse_table, "data_in", check=lambda v: v > 999, max_iters=4)
    assert not r.passed and r.iterations == 4 and len(r.history) == 4


def test_program_verify_never_continues_after_a_fault():
    seq = MockCellSequencer(fault_at=2)
    with pytest.raises(SequenceError, match="faulted at step 1"):
        program_verify(seq, _pulse_table, "data_in", check=lambda v: False, max_iters=10)
    assert seq.runs == 2


# ---------------------------------------------------------------- gen_svh --phase7

import re as _re


def _field(text, name, k, w):
    m = _re.search(rf"localparam logic \[\d+:0\] {name} = \d+'h([0-9a-f]+);", text)
    assert m, name
    return (int(m.group(1), 16) >> (k * w)) & ((1 << w) - 1)


def test_phase7_package_packs_each_step_at_k_times_w():
    text, warns = gen_svh.generate_phase7()
    t = load_sequence(CONFIG)
    assert "package phase7_cfg_pkg;" in text and "localparam logic [4:0] N_STEPS = 5'd6;" in text
    for k, st in enumerate(t.steps):
        assert _field(text, "STEP_SIG_MASK", k, 5) == sum(int(m) << i for i, m in enumerate(st.sig_mask))
        assert _field(text, "STEP_COND", k, 3) == st.cond
        assert _field(text, "STEP_COND_ARG", k, 32) == st.cond_arg
        assert _field(text, "STEP_TIMEOUT", k, 32) == st.timeout
        assert _field(text, "CLK_PARAM_A", k, 32) == st.sig[0].param_a
        assert _field(text, "DATA_DATA", k, 16) == st.sig[2].data
        assert _field(text, "DATA_IN_BITS", k, 32) == st.cap[2].bits
    # steps past N_STEPS repeat the last one with an empty mask's worth of effect
    assert _field(text, "STEP_COND_ARG", 15, 32) == t.steps[-1].cond_arg
    assert "DATA_IN_EXPECT = 16'h00a5;" in text and "DATA_IN_EXPECT_MASK = 16'h00ff;" in text


def test_phase7_scaled_copy_is_marked_and_cli_refuses_it_without_out(tmp_path, capsys):
    text, _ = gen_svh.generate_phase7(scale=1e-4)
    assert "TIME-SCALED x0.0001: SIMULATION ONLY" in text
    assert _field(text, "STEP_COND_ARG", 0, 32) == 10_000
    with pytest.raises(SystemExit):
        gen_svh.main(["--phase7", "--time-scale", "1e-4"])
    assert "simulation only" in capsys.readouterr().err
    out = tmp_path / "pkg.sv"
    gen_svh.main(["--phase7", "--time-scale", "1e-4", "--out", str(out)])
    assert "SIMULATION ONLY" in out.read_text()


def test_phase7_bad_sequence_writes_nothing(tmp_path, capsys):
    bad = tmp_path / "bad.yaml"
    doc = yaml.safe_load(CONFIG.read_text())
    doc["steps"][2]["until"].pop("timeout")
    bad.write_text(yaml.safe_dump(doc))
    with pytest.raises(SequenceError, match="needs a 'timeout'"):
        gen_svh.generate_phase7(bad)
