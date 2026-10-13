`timescale 1ns / 1ps
//==========================================================================
// integration_tb — lightweight sanity check that run_ctrl, sig_cell and
// cap_cell interoperate (not required by generic_controller_prompt.md's
// Phase 3 module list on its own, but cheap given the three already have
// passing unit tests, and it catches wiring mistakes before Phase 4's real
// top-level integration). One sig_cell driven as a CLOCK, feeding one
// cap_cell in PERIOD mode through a plain wire (standing in for an FMC
// pin + 2-FF sync, both external to these cells) -- same RUN/APPLY signals
// from one run_ctrl drive both, exactly as generic_controller_prompt.md §2
// describes ("sharing one timebase and one global RUN/STOP").
//==========================================================================
module integration_tb;

    localparam int TICK_W = 32;

    logic clk = 0;
    logic rst_n;
    logic run_set, run_clear, apply_cmd;
    logic run, apply;

    run_ctrl u_run_ctrl (
        .clk(clk), .rst_n(rst_n),
        .run_set(run_set), .run_clear(run_clear), .apply_cmd(apply_cmd),
        .run(run), .apply(apply)
    );

    // one sig_cell configured as a CLOCK: period=25 ticks, high=10 ticks, free-running
    logic [2:0]        clk_cfg_type       = 3'd3; // TYPE_CLOCK
    logic              clk_cfg_idle       = 1'b0;
    logic [TICK_W-1:0] clk_cfg_delay      = 32'd0;
    logic [TICK_W-1:0] clk_cfg_param_a    = 32'd25;
    logic [TICK_W-1:0] clk_cfg_param_b    = 32'd10;
    logic [TICK_W-1:0] clk_cfg_cycles     = 32'd0; // free-running
    logic              pin_out, rising_edge_o, falling_edge_o, active_o, done_o;

    sig_cell #(.TICK_W(TICK_W), .SERIAL_W(8)) u_sig_cell (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .cfg_type(clk_cfg_type), .cfg_idle_level(clk_cfg_idle),
        .cfg_delay(clk_cfg_delay), .cfg_param_a(clk_cfg_param_a), .cfg_param_b(clk_cfg_param_b),
        .cfg_cycles(clk_cfg_cycles), .cfg_msb_first(1'b1), .cfg_data(8'h00), .cfg_bits(32'd0),
        .shift_strobe(1'b0),
        .pin_out(pin_out), .rising_edge(rising_edge_o), .falling_edge(falling_edge_o),
        .active(active_o), .done(done_o)
    );

    // the "FMC pin + external 2-FF sync" that would sit between a real chip
    // output and cap_cell -- modeled here as a plain wire plus one extra
    // register, standing in for that synchronizer stage.
    logic sync_in_d1, sync_in;
    always_ff @(posedge clk) begin
        sync_in_d1 <= pin_out;
        sync_in    <= sync_in_d1;
    end

    logic [1:0]        cap_cfg_mode = 2'd2; // MODE_PERIOD
    logic [TICK_W-1:0] period_ticks, high_ticks;
    logic              period_valid;
    logic [TICK_W-1:0] edge_count_unused;
    logic [7:0]        capture_reg_unused;
    logic              cap_done_unused;

    cap_cell #(.TICK_W(TICK_W), .CAP_W(8)) u_cap_cell (
        .clk(clk), .rst_n(rst_n), .run(run), .apply(apply),
        .sync_in(sync_in),
        .cfg_mode(cap_cfg_mode), .cfg_msb_first(1'b1), .cfg_bits(32'd0),
        .capture_strobe(1'b0),
        .level_out(), .edge_count(edge_count_unused),
        .period_ticks(period_ticks), .high_ticks(high_ticks), .period_valid(period_valid),
        .capture_reg(capture_reg_unused), .done(cap_done_unused)
    );

    always #5 clk = ~clk;

    int fails = 0, checks = 0;
    task automatic check(logic cond, string msg);
        checks++;
        if (cond) $display("  PASS: %s", msg);
        else begin $display("  FAIL: %s", msg); fails++; end
    endtask

    task automatic tick(int n = 1);
        repeat (n) begin @(posedge clk); #1; end
    endtask

    initial begin
        rst_n = 0; run_set = 0; run_clear = 0; apply_cmd = 0;
        tick(3);
        @(negedge clk); rst_n = 1;
        tick(2);

        @(negedge clk); apply_cmd = 1;
        @(negedge clk); apply_cmd = 0;
        tick(3);

        @(negedge clk); run_set = 1;
        tick(3);
        @(negedge clk); run_set = 0;

        $display("\n-- integration: one run_ctrl driving a CLOCK sig_cell into a PERIOD cap_cell --");
        begin
            int valids = 0;
            for (int i = 0; i < 200; i++) begin
                tick(1);
                if (period_valid) begin
                    valids++;
                    check(period_ticks == 25, $sformatf("cap_cell measured period=25 through the sig_cell+sync chain (got %0d)", period_ticks));
                    check(high_ticks == 10, $sformatf("cap_cell measured high=10 through the sig_cell+sync chain (got %0d)", high_ticks));
                end
            end
            check(valids >= 3, $sformatf("saw multiple period measurements over 200 ticks (got %0d)", valids));
        end

        @(negedge clk); run_clear = 1;
        @(negedge clk); run_clear = 0;
        tick(3);
        check(pin_out == clk_cfg_idle, "sig_cell's pin_out returns to idle after STOP");

        $display("\n================================================");
        if (fails == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else $display("%0d CHECK(S) FAILED out of %0d", fails, checks);
        $display("================================================\n");
        $finish;
    end

endmodule
