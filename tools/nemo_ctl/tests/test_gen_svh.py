from nemo_ctl.gen_svh import generate


def test_generated_svh_has_a_block_per_test_pair():
    text = generate()
    for name in ("TEST_CLOCK", "TEST_PULSE", "TEST_SERIAL", "TEST_LOW", "TEST_HIGH"):
        assert f"localparam int {name}_LA_PAIR" in text


def test_generated_svh_quantizes_the_100hz_test_clock_exactly():
    text = generate()
    # 100 Hz on a 100 MHz timebase -> period = 1,000,000 ticks, 50% high = 500,000
    assert "localparam logic [TICK_W-1:0] TEST_CLOCK_PARAM_A = 1000000;" in text
    assert "localparam logic [TICK_W-1:0] TEST_CLOCK_PARAM_B = 500000;" in text


def test_generated_svh_is_balanced_and_guarded():
    text = generate()
    assert text.count("`ifndef") == 1
    assert text.count("`endif") == 1
    assert "package nemo_cfg_pkg;" in text
    assert "endpackage" in text


def test_la_pairs_are_0_through_4_no_duplicates():
    text = generate()
    pairs = []
    for line in text.splitlines():
        if "_LA_PAIR = " in line:
            pairs.append(int(line.split("=")[1].strip().rstrip(";")))
    assert sorted(pairs) == [0, 1, 2, 3, 4]
