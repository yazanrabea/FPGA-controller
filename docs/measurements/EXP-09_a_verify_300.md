# Verify: mode sequence exp09_verify_vchip.yaml

- date: 2026-11-02 14:36
- config: ../config/exp09_verify_vchip.yaml
- duration: the sequence's steps
- link: JTAG (J17)
- result: **PASS** (26 pass, 0 fail, 3 not judged, 300 runs)

| pin | check | expected | measured | result | note |
|---|---|---|---|---|---|
| (run) | status | `done, no fault` | `done, last step 2` | PASS | 300/300 pass |
| sipo_out | level | `1` | `1` | PASS | 300/300 pass |
| piso_out | serial | `0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6` | `0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6` | PASS | 300/300 pass |
| dft0_buff | - | `-` | `level 0, edges 0, period 0 ticks` | - | no expect set |
| dft1_buff | - | `-` | `level 0, edges 0, period 0 ticks` | - | no expect set |
| (readback) | readback | `-` | `22 pins from the output registers (no pads: vchip_top), window 31953 ticks (319.53 us)` | - |  |
| clk | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| reset | readback | `edges 0, saw 1, end 1` | `edges 0, saw 1, end 1` | PASS | 300/300 pass |
| set | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| rst_dsa | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| pulse | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s0_p | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s1_p | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s2_p | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| b0_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| b1_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| b2_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s0_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s1_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s2_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| s3_dft | readback | `edges 0, saw 0, end 0` | `edges 0, saw 0, end 0` | PASS | 300/300 pass |
| sipo_in | readback | `edges 32, saw 0/1, end 0, period 800, high 300` | `edges 32, saw 0/1, end 0, period 800, high 300` | PASS | 300/300 pass |
| clk_sipo | readback | `edges 136, saw 0/1, end 0, period 100, high 50` | `edges 136, saw 0/1, end 0, period 100, high 50` | PASS | 300/300 pass |
| cs | readback | `edges 1, saw 0/1, end 0, high 100` | `edges 1, saw 0/1, end 0, high 100` | PASS | 300/300 pass |
| rst_sipo | readback | `edges 0, saw 1, end 1` | `edges 0, saw 1, end 1` | PASS | 300/300 pass |
| clk_piso | readback | `edges 168, saw 0/1, end 0, period 100, high 50` | `edges 168, saw 0/1, end 0, period 100, high 50` | PASS | 300/300 pass |
| shift | readback | `edges 1, saw 0/1, end 1` | `edges 1, saw 0/1, end 1` | PASS | 300/300 pass |
| rst_piso | readback | `edges 0, saw 1, end 1` | `edges 0, saw 1, end 1` | PASS | 300/300 pass |
| sipo_in frame | readback | `136 bits 0x5AA55A0FF0123456789ABCDEF0C3C3E7E7` | `136 bits 0x5AA55A0FF0123456789ABCDEF0C3C3E7E7` | PASS | 300/300 pass |
