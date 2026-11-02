# Verify: mode sequence chip_sim_test.yaml

- date: 2026-11-02 12:29
- config: ../config/chip_sim_test.yaml
- duration: the sequence's steps
- link: JTAG (J17)
- result: **PASS** (24 pass, 0 fail, 5 not judged, 100 runs)

| pin | check | expected | measured | result | note |
|---|---|---|---|---|---|
| (run) | status | `done, no fault` | `done, last step 2` | PASS | 100/100 pass |
| sipo_out | - | `-` | `level 0, edges 0, period 0 ticks` | - | no expect set |
| piso_out | - | `-` | `level 0, edges 0, period 0 ticks, capture 0x000000000000000000000000000000000000000000` | - | no expect set |
| dft0_buff | - | `-` | `level 0, edges 0, period 0 ticks` | - | no expect set |
| dft1_buff | - | `-` | `level 0, edges 0, period 0 ticks` | - | no expect set |
| (readback) | readback | `-` | `22 pins at the pads, window 31953 ticks (319.53 us)` | - |  |
| clk | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| reset | readback | `edges 0, saw 1, end 1` | `edges 0, saw 1, end 1` | PASS | 100/100 pass |
| set | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| rst_dsa | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| pulse | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s0_p | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s1_p | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s2_p | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| b0_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| b1_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| b2_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s0_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s1_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s2_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| s3_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 100/100 pass |
| sipo_in | readback | `edges 32, saw 0/1, end 0, period 800, high 300` | `edges 32, saw 0/1, end 0, period 800, high 300` | PASS | 100/100 pass |
| clk_sipo | readback | `edges 136, saw 0/1, end 0, period 100, high 50` | `edges 136, saw 0/1, end 0, period 100, high 50` | PASS | 100/100 pass |
| cs | readback | `edges 1, saw 0/1, end 0, high 100` | `edges 1, saw 0/1, end 0, high 100` | PASS | 100/100 pass |
| rst_sipo | readback | `edges 0, saw 1, end 1` | `edges 0, saw 1, end 1` | PASS | 100/100 pass |
| clk_piso | readback | `edges 168, saw 0/1, end 0, period 100, high 50` | `edges 168, saw 0/1, end 0, period 100, high 50` | PASS | 100/100 pass |
| shift | readback | `edges 1, saw 0/1, end 1` | `edges 1, saw 0/1, end 1` | PASS | 100/100 pass |
| rst_piso | readback | `edges 0, saw 1, end 1` | `edges 0, saw 1, end 1` | PASS | 100/100 pass |
| sipo_in frame | readback | `136 bits 0x5AA55A0FF0123456789ABCDEF0C3C3E7E7` | `136 bits 0x5AA55A0FF0123456789ABCDEF0C3C3E7E7` | PASS | 100/100 pass |
