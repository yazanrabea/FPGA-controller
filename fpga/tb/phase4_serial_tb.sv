`timescale 1ns / 1ps
// phase4_loopback_top SERIAL pair (pair 2) end to end, which phase4_loopback_top_tb can't
// reach (10 Hz strobe = 80M ticks per frame). Runs against a copy of nemo_cfg_pkg.sv with the
// strobe sped up to 1 MHz (run_phase4_sim.sh makes it in a temp folder; never a bitstream).
// Case 1: jumper in -> LD2 on. Case 2: pair 2 read-back held 0 (jumper pulled) -> LD2 off.
// The pre-fix checker failed both (EXP-01, 2026-10-22: compared 0xA5 with 0x00).
module phase4_serial_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic [4:0] sw; wire [7:0] led; wire [31:0] fmc_pins;
    logic break2 = 0;
    phase4_loopback_top dut (.clk(clk), .sw(sw), .led(led), .fmc_pins(fmc_pins));
    assign fmc_pins[16] = fmc_pins[0];
    assign fmc_pins[17] = fmc_pins[1];
    assign fmc_pins[18] = break2 ? 1'b0 : fmc_pins[2];
    assign fmc_pins[19] = fmc_pins[3];
    assign fmc_pins[20] = fmc_pins[4];
    int fails = 0;
    task automatic run_case(input logic brk, input logic want, input string name);
        break2 = brk; sw = 5'b00010; repeat (50) @(posedge clk);
        sw[4] = 1'b1; repeat (2000) @(posedge clk);   // 8 bits x 100 ticks + margin
        $display("  %s: %s  LD2=%0b capture=%h", (led[2] == want) ? "PASS" : "FAIL", name, led[2], dut.capture_reg_serial);
        if (led[2] != want) fails++;
        sw[4] = 1'b0; repeat (50) @(posedge clk);
    endtask
    initial begin
        run_case(1'b0, 1'b1, "jumper in -> 0xA5 captured, LD2 on");
        run_case(1'b1, 1'b0, "jumper pulled -> LD2 stays off");
        if (fails == 0) $display("ALL TESTS PASSED (2 checks)"); else $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end
endmodule
