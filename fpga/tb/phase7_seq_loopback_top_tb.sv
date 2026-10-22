`timescale 1ns / 1ps
//==========================================================================
// phase7_seq_loopback_top_tb
//
// Phase 7.3: the bring-up top with the demo sequence, using a TIME-SCALED
// copy of its package (scripts/run_phase7_sim.sh generates
// config/phase7_seq_loopback.yaml at x1e-4: same steps, 10^4 fewer ticks).
// Every expected number is read from that package, nothing hard-coded, so
// the checks hold at any scale.
//
// Models the 5 jumper wires (fmc_pins[i+16] = fmc_pins[i]); a "pulled"
// jumper reads 0, as the XDC's PULLDOWN makes it on the board.
// Timing rule used below (from sig_cell/seq_engine): a cell applied at
// tick A with delay d changes its pin at tick A + 2 + d.
//
//   RUN 1: full sequence -> every step boundary, pin pulse/clock timing,
//          data_in == 0xA5 (LD6), done (LD4), last step 5 on LD2-0.
//   RUN 2: jumper J2-20 (en) pulled -> FAULT at step 4 (LD5), pins idle.
//   RUN 3: sw[4] down during step 2 -> aborted (LD7), last step 2.
//   Also: a sw[4] glitch shorter than the debounce window does nothing.
//==========================================================================
module phase7_seq_loopback_top_tb;

    localparam int TW = phase7_cfg_pkg::TICK_W;
    localparam int DB = 20;   // debounce ticks for the sim (hardware default: 2,000,000)

    logic clk = 0;
    always #5 clk = ~clk;
    int unsigned cyc = 0;
    always @(posedge clk) cyc++;

    logic [4:0] sw = '0;
    logic [7:0] led;
    wire  [31:0] fmc_pins;
    logic [4:0] jumper = 5'b11111;

    phase7_seq_loopback_top #(.DEBOUNCE_TICKS(DB)) dut (
        .clk(clk), .sw(sw), .led(led), .fmc_pins(fmc_pins));

    genvar g;
    generate
        for (g = 0; g < 5; g = g + 1) begin : g_jumper
            assign fmc_pins[g + 16] = jumper[g] ? fmc_pins[g] : 1'b0;
        end
    endgenerate

    // ---- package helpers ----
    function automatic int unsigned arg_of(input int k);
        return phase7_cfg_pkg::STEP_COND_ARG[k*TW +: TW];
    endfunction

    // ---- checks ----
    int fails = 0, checks = 0;
    task automatic check(input logic cond, input string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask
    task automatic tick(input int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    // ---- monitors (negedge: DUT registers settled; cyc = tick the value appeared) ----
    int unsigned apply_cyc [0:15];
    int          n_apply;
    int unsigned rst_fall, rst_rise, clk_first_rise, clk_last_rise, cs_rise, cs_fall;
    int unsigned data_done_cyc, cs_count_cyc;
    int          clk_rises, clk_falls, clk_bad_period, rst_falls;
    logic [4:0]  p_d = 5'b0;

    task automatic clear_mon();
        n_apply = 0; rst_fall = 0; rst_rise = 0; clk_first_rise = 0; clk_last_rise = 0;
        cs_rise = 0; cs_fall = 0; data_done_cyc = 0; cs_count_cyc = 0;
        clk_rises = 0; clk_falls = 0; clk_bad_period = 0; rst_falls = 0;
    endtask

    always @(negedge clk) begin
        if (dut.step_start) begin apply_cyc[n_apply] = cyc; n_apply++; end
        if (dut.busy) begin
            // rst (pin 1)
            if (!fmc_pins[1] && p_d[1]) begin rst_falls++; rst_fall = cyc; end
            if (fmc_pins[1] && !p_d[1]) rst_rise = cyc;
            // clk (pin 0)
            if (fmc_pins[0] && !p_d[0]) begin
                if (clk_rises > 0 && cyc - clk_last_rise != phase7_cfg_pkg::CLK_PARAM_A[2*TW +: TW])
                    clk_bad_period++;
                if (clk_rises == 0) clk_first_rise = cyc;
                clk_last_rise = cyc; clk_rises++;
            end
            if (!fmc_pins[0] && p_d[0]) clk_falls++;
            // cs (pin 3)
            if (fmc_pins[3] && !p_d[3]) cs_rise = cyc;
            if (!fmc_pins[3] && p_d[3]) cs_fall = cyc;
            if (dut.cap_done[2] && data_done_cyc == 0) data_done_cyc = cyc;
            if (dut.step == 3 && dut.cap_edges[3*TW +: TW] >= 1 && cs_count_cyc == 0 && cyc >= apply_cyc[3] + 2)
                cs_count_cyc = cyc;
        end
        p_d = fmc_pins[4:0];
    end

    task automatic flip_sw(input logic v);
        sw[4] = v; tick(DB + 6);   // sync (2) + debounce (DB) + a few ticks for start/abort to land
    endtask

    task automatic wait_not_busy(input int max_cycles);
        int k;
        for (k = 0; k < max_cycles && led[3]; k++) tick(1);
        tick(3);
    endtask

    initial begin
        #(50ms); $display("FAIL: watchdog"); $finish;
    end

    initial begin
        clear_mon();
        tick(30);
        $display("\n== after power-on: step 0 preloaded ==");
        check(led == 8'b0000_0000, $sformatf("LEDs all off before START (%b)", led));
        check(fmc_pins[1] == 1'b1, "rst pin = 1 (step 0: HIGH, inactive) -- not sig_cell's reset 0");
        check(fmc_pins[0] == 0 && fmc_pins[2] == 0 && fmc_pins[3] == 0 && fmc_pins[4] == 0,
              "clk, data, cs, en = 0");

        $display("\n== a sw[4] glitch shorter than the debounce window ==");
        sw[4] = 1; tick(DB / 2); sw[4] = 0; tick(DB + 10);
        check(!led[3] && n_apply == 0, "no START");

        $display("\n== RUN 1: full sequence ==");
        clear_mon();
        flip_sw(1);
        check(led[3], "LD3 busy after sw[4] up");
        wait_not_busy(400_000);
        check(n_apply == 6, $sformatf("6 step starts (%0d)", n_apply));
        check(apply_cyc[1] - apply_cyc[0] == arg_of(0),
              $sformatf("step 0 'idle' lasted exactly %0d ticks (%0d)", arg_of(0), apply_cyc[1] - apply_cyc[0]));
        check(apply_cyc[2] - apply_cyc[1] == arg_of(1),
              $sformatf("step 1 'reset' lasted exactly %0d ticks (%0d)", arg_of(1), apply_cyc[2] - apply_cyc[1]));
        check(rst_falls == 1 && rst_fall == apply_cyc[1] + 2 + phase7_cfg_pkg::RST_DELAY[1*TW +: TW],
              $sformatf("rst pulled low once, at step 1 start + 2 (%0d vs %0d)", rst_fall, apply_cyc[1]));
        check(rst_rise - rst_fall == phase7_cfg_pkg::RST_PARAM_A[1*TW +: TW],
              $sformatf("rst low for exactly %0d ticks (%0d)", phase7_cfg_pkg::RST_PARAM_A[1*TW +: TW], rst_rise - rst_fall));
        check(clk_first_rise == apply_cyc[2] + 2 + phase7_cfg_pkg::CLK_DELAY[2*TW +: TW],
              $sformatf("clk's first rise = step 2 start + 2 + delay (%0d)", clk_first_rise - apply_cyc[2]));
        check(clk_rises == phase7_cfg_pkg::CLK_CYCLES[2*TW +: TW] && clk_falls == clk_rises && clk_bad_period == 0,
              $sformatf("clk: %0d rising / %0d falling edges, every period %0d ticks", clk_rises, clk_falls,
                        phase7_cfg_pkg::CLK_PARAM_A[2*TW +: TW]));
        check(data_done_cyc == clk_last_rise + 1,
              $sformatf("data_in finished on clk's 8th rising edge (+1 register): rise %0d, done %0d",
                        clk_last_rise, data_done_cyc));
        check(apply_cyc[3] == data_done_cyc + 1,
              $sformatf("step 2 ended the tick after data_in captured (%0d -> %0d)", data_done_cyc, apply_cyc[3]));
        check(clk_last_rise < apply_cyc[3] && clk_falls == 8,
              "clk finished its 8th cycle inside step 3 without being restarted");
        check((dut.data_in_reg & phase7_cfg_pkg::DATA_IN_EXPECT_MASK) == phase7_cfg_pkg::DATA_IN_EXPECT,
              $sformatf("data_in captured %h (expect %h)", dut.data_in_reg & phase7_cfg_pkg::DATA_IN_EXPECT_MASK,
                        phase7_cfg_pkg::DATA_IN_EXPECT));
        check(cs_rise == apply_cyc[3] + 2 + phase7_cfg_pkg::CS_DELAY[3*TW +: TW]
              && cs_fall - cs_rise == phase7_cfg_pkg::CS_PARAM_A[3*TW +: TW],
              $sformatf("cs: rises at step 3 start + 2 + delay, high %0d ticks", cs_fall - cs_rise));
        check(cs_count_cyc != 0 && apply_cyc[4] == cs_count_cyc + 1,
              $sformatf("step 3 ended the tick after cs_in counted 1 edge (%0d -> %0d)", cs_count_cyc, apply_cyc[4]));
        check(apply_cyc[5] - apply_cyc[4] == 3,
              $sformatf("step 4 'confirm' (en_in already 1) ended on its 3rd tick (%0d)", apply_cyc[5] - apply_cyc[4]));
        check(led[4] && !led[5] && !led[7] && led[6] && led[2:0] == 3'd5,
              $sformatf("LEDs: done, no fault/abort, data match, last step 5 (%b)", led));
        check(fmc_pins[1] == 1 && fmc_pins[0] == 0 && fmc_pins[2] == 0 && fmc_pins[3] == 0 && fmc_pins[4] == 0,
              "after the sequence: pins back to step 0 (rst 1, others 0)");
        tick(1000);
        check((dut.data_in_reg & phase7_cfg_pkg::DATA_IN_EXPECT_MASK) == phase7_cfg_pkg::DATA_IN_EXPECT && led[6],
              "data_in's result is still readable 1000 ticks after the sequence ended");

        $display("\n== RUN 2: jumper J2-20 (en) pulled ==");
        flip_sw(0);
        jumper[4] = 1'b0;
        clear_mon();
        flip_sw(1);
        wait_not_busy(400_000);
        check(led[5] && !led[4] && led[2:0] == 3'd4, $sformatf("LD5 FAULT, step 4 on LD2-0 (%b)", led));
        check(apply_cyc[4] != 0 && n_apply == 5, "faulted in step 4, no step 5");
        check(fmc_pins[4] == 0 && fmc_pins[1] == 1, "after the fault: en back to 0, rst to 1");
        jumper[4] = 1'b1;

        $display("\n== RUN 3: sw[4] down during step 2 ==");
        flip_sw(0);
        clear_mon();
        flip_sw(1);
        while (dut.step != 2) tick(1);
        tick(500);
        flip_sw(0);
        tick(3);
        check(led[7] && !led[3] && !led[4] && !led[5] && led[2:0] == 3'd2,
              $sformatf("LD7 aborted at step 2, not busy (%b)", led));
        check(fmc_pins[0] == 0 && fmc_pins[2] == 0 && fmc_pins[1] == 1, "after abort: clk/data 0, rst 1");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
