`timescale 1ns / 1ps
//==========================================================================
// chip_top
//
// Chip pipeline step C4: the controller for the real chip. The Phase 7
// round-2 sequencer (step table loaded from the PC over the JTAG link,
// docs/link_register_map.md v2) driving one sig_cell per chip input and one
// cap_cell per chip output: 22 + 4 cells instead of phase7_link_top's 5 + 5.
//
// Everything chip-specific comes from the generated fpga/src/gen/chip_pkg.sv
// and fpga/constraints/chip_top.xdc (tools/nemo_ctl/gen_svh.py --chip, from
// config/nemo_config.yaml's pin_map); this file has no pin, width or offset
// of its own:
//   chip_out[i] = sig cell i (drives chip input i), chip_in[j] = cap cell j,
//   order = sequence.chip_target() = pin_db order (names: chip_pkg SIG_* / CAP_*).
//   sipo_in (SIPO_CELL, SERIAL_W 136) shifts on clk_sipo's edge, piso_out
//   (PISO_CELL, CAP_W 168) captures on clk_piso's edge; which edges is
//   chip_pkg SIPO_ON_FALLING / PISO_ON_FALLING (UNCONFIRMED, Dima).
//
//   PC --JTAG (J17)--> link_frame --bus--> v2 registers / step-table RAM (seq_bank)
//   seq_bank's next-step bank --> cells' cfg, header --> seq_engine
//   Commands: RUN = start, STOP = abort, APPLY = re-apply step 0 (idle state).
//
// Capture region (per cap cell, CAP_STRIDE bytes): flags, edge count, PERIOD
// and HIGH ticks (for DFT phi1/phi2 measurements, Phase 8), capture register.
// Cell lookup by range compare, not (addr - CAP_BASE) / CAP_STRIDE: the stride
// (40) isn't a power of 2, and a divide failed 100 MHz timing in link_ctrl.sv
// (docs/issues.md, 2026-10-22).
//
// Outputs come straight from each sig_cell's output register; inputs get a
// 2-FF synchronizer (CLAUDE.md §8). LEDs: LD0-LD2 step (current while running,
// last afterwards), LD3 busy, LD4 done, LD5 FAULT, LD6 LATE, LD7 link error.
//==========================================================================
module chip_top (
    input  logic                     clk,        // 100 MHz ZedBoard system clock
    output logic [7:0]               led,
    output logic [chip_pkg::N_SIG-1:0] chip_out,  // -> chip inputs (DRIVE 4, SLEW SLOW in the XDC)
    input  logic [chip_pkg::N_CAP-1:0] chip_in    // <- chip outputs (PULLDOWN in the XDC)
);
    localparam int TW  = 32;
    localparam int NS  = chip_pkg::N_SIG;
    localparam int NC  = chip_pkg::N_CAP;
    localparam int SW  = chip_pkg::STEP_W;
    localparam int EB  = chip_pkg::ENTRY_BYTES;
    localparam int UB  = chip_pkg::USED_BYTES;
    localparam int HB  = chip_pkg::HDR_BYTES;
    localparam int CS  = chip_pkg::CAP_STRIDE;
    localparam int CD  = chip_pkg::CAP_DATA;
    localparam int CB  = chip_pkg::CAP_BYTES;
    localparam int TAW = SW + $clog2(EB);              // table byte-address width
    localparam logic [15:0] TBASE = chip_pkg::TABLE_BASE;
    localparam logic [15:0] CBASE = chip_pkg::CAP_BASE;
    localparam int V2_PERIOD = 5, V2_HIGH = 9;         // link.py V2_CAP_PERIOD / V2_CAP_HIGH

    // ---- power-on reset (no reset button wired on this board) ----
    logic [3:0] por_cnt = 4'd0;
    logic       rst_n;
    always_ff @(posedge clk) if (por_cnt != 4'hF) por_cnt <= por_cnt + 4'd1;
    assign rst_n = (por_cnt == 4'hF);

    // ---- JTAG link + frame engine ----
    logic [7:0] rx_byte, tx_byte;
    logic rx_byte_valid, rx_overflow_jtag, tx_send, tx_busy;
    jtag_link_bscan u_jtag (.clk(clk), .rst_n(rst_n),
        .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
        .dn_overflow(rx_overflow_jtag));

    logic        bus_we, bus_re, cmd_apply, cmd_run, cmd_stop, rx_overflow;
    logic [15:0] bus_waddr, bus_raddr;
    logic [7:0]  bus_wdata, bus_rdata;
    link_frame #(.MAX_PAYLOAD(255), .CAP_BASE(CBASE), .STATUS_ADDR(chip_pkg::REG_STATUS)) u_frame (
        .clk(clk), .rst_n(rst_n),
        .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
        .bus_we(bus_we), .bus_waddr(bus_waddr), .bus_wdata(bus_wdata),
        .bus_re(bus_re), .bus_raddr(bus_raddr), .bus_rdata(bus_rdata),
        .cmd_apply(cmd_apply), .cmd_run(cmd_run), .cmd_stop(cmd_stop),
        .rx_overflow(rx_overflow));

    // ---- engine + bank ----
    logic [SW-1:0] step, last_step, fetch_step;
    logic run, busy, seq_done, fault, aborted, late, step_start, apply_tick, fetch_ready;
    logic [NS-1:0] sig_apply;
    logic [NC-1:0] cap_apply;
    wire  [NS-1:0] sig_done, pin_out, sig_rise, sig_fall;   // one driver per bit: wire
    wire  [NC-1:0] cap_done, cap_level;
    wire  [NC*TW-1:0] cap_edges, cap_period, cap_high;
    logic [UB*8-1:0] nx;      // next-step bank: every cell's cfg comes from here
    logic [HB*8-1:0] hdr;     // header of the current step
    logic [SW:0] n_steps;

    logic in_table, tbl_we;
    assign in_table = (bus_waddr >= TBASE) && (bus_waddr < TBASE + (2 ** SW) * EB);
    assign tbl_we   = bus_we && in_table && !busy;

    seq_bank #(.STEP_W(SW), .ENTRY_BYTES(EB), .USED_BYTES(UB), .HDR_BYTES(HB)) u_bank (
        .clk(clk), .rst_n(rst_n),
        .wr_en(tbl_we), .wr_addr(TAW'(bus_waddr - TBASE)), .wr_data(bus_wdata),
        .fetch_step(fetch_step), .fetch_ready(fetch_ready), .apply_tick(apply_tick),
        .next_entry(nx), .hdr(hdr));

    seq_engine #(.N_SIG(NS), .N_CAP(NC), .TICK_W(TW), .STEP_W(SW)) u_engine (
        .clk(clk), .rst_n(rst_n), .start(cmd_run), .abort(cmd_stop), .preload(cmd_apply),
        .n_steps(n_steps),
        .step_sig_mask(hdr[chip_pkg::H_SIG_MASK*8 +: NS]),
        .step_cap_mask(hdr[chip_pkg::H_CAP_MASK*8 +: NC]),
        .step_cond(hdr[chip_pkg::H_COND*8 +: 3]),
        .step_cond_cell(hdr[chip_pkg::H_COND_CELL*8 +: 8]),
        .step_cond_arg(hdr[chip_pkg::H_COND_ARG*8 +: TW]),
        .step_timeout(hdr[chip_pkg::H_TIMEOUT*8 +: TW]),
        .fetch_step(fetch_step), .fetch_ready(fetch_ready),
        .sig_done(sig_done), .cap_done(cap_done), .cap_level(cap_level), .cap_edges(cap_edges),
        .step(step), .run(run), .sig_apply(sig_apply), .cap_apply(cap_apply), .apply_tick(apply_tick),
        .busy(busy), .seq_done(seq_done), .fault(fault), .aborted(aborted), .late(late),
        .last_step(last_step), .step_start(step_start));

    // ---- v2 registers ----
    logic [7:0] scratch;
    logic       table_rejected;   // a table / N_STEPS write arrived while busy (sticky)
    logic       link_error;       // JTAG down-FIFO overrun or link input-FIFO overflow (sticky)
    logic [7:0] status;
    assign status = {rx_overflow, table_rejected, late, aborted, fault, seq_done, busy, run};

    wire [NC-1:0][CB*8-1:0] cap_reg;   // each cap cell's capture register, zero-extended

    function automatic logic [7:0] read_byte(input logic [15:0] a);
        int k, off;
        logic [31:0] e, pr, hi;
        logic [CB*8-1:0] c;
        if (a == 16'h0000)                     return scratch;
        if (a == chip_pkg::REG_STATUS)    return status;
        if (a == chip_pkg::REG_STEP)      return 8'(step);
        if (a == chip_pkg::REG_LAST_STEP) return 8'(last_step);
        if (a == chip_pkg::REG_N_STEPS)   return 8'(n_steps);
        if (a >= CBASE && a < CBASE + NC * CS) begin
            k = 0; off = 0;
            for (int i = 0; i < NC; i++)               // range compare per cell, no divide
                if (a >= CBASE + i * CS && a < CBASE + (i + 1) * CS) begin
                    k = i; off = a - (CBASE + i * CS);
                end
            c  = cap_reg[k];
            e  = cap_edges[k*TW +: TW];
            pr = cap_period[k*TW +: TW];
            hi = cap_high[k*TW +: TW];
            if (off == 0) return {5'b0, cap_done[k], 1'b0, cap_level[k]};
            if (off >= 1 && off < 1 + 4)                 return e[(off-1)*8 +: 8];
            if (off >= V2_PERIOD && off < V2_PERIOD + 4) return pr[(off-V2_PERIOD)*8 +: 8];
            if (off >= V2_HIGH && off < V2_HIGH + 4)     return hi[(off-V2_HIGH)*8 +: 8];
            if (off >= CD && off < CD + CB)              return c[(off-CD)*8 +: 8];
            return 8'h00;
        end
        return 8'h00;  // table (write-only) and everything unused
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch        <= '0;
            n_steps        <= 1;
            table_rejected <= 1'b0;
            link_error     <= 1'b0;
            bus_rdata      <= '0;
        end else begin
            if (rx_overflow_jtag || rx_overflow) link_error <= 1'b1;
            if (bus_re) bus_rdata <= read_byte(bus_raddr);
            if (bus_we) begin
                if (bus_waddr == 16'h0000) scratch <= bus_wdata;
                if (bus_waddr == chip_pkg::REG_STATUS) table_rejected <= 1'b0;
                if (bus_waddr == chip_pkg::REG_N_STEPS) begin
                    if (busy) table_rejected <= 1'b1;
                    else n_steps <= (bus_wdata == 0) ? 1 : (bus_wdata > 2 ** SW) ? (2 ** SW) : bus_wdata[SW:0];
                end
                if (in_table && busy) table_rejected <= 1'b1;
            end
        end
    end

    // ---- one sig cell per chip input; cfg = the next-step bank (latched on APPLY) ----
    genvar g;
    generate
        for (g = 0; g < NS; g++) begin : g_sig
            localparam int B = chip_pkg::SIG_BASE[g];
            localparam int W = chip_pkg::SIG_SERIAL_W[g];
            wire strobe;
            if (g == chip_pkg::SIPO_CELL) begin : g_strobe
                assign strobe = chip_pkg::SIPO_ON_FALLING ? sig_fall[chip_pkg::SIPO_CLK_CELL]
                                                          : sig_rise[chip_pkg::SIPO_CLK_CELL];
            end else begin : g_no_strobe
                assign strobe = 1'b0;
            end
            sig_cell #(.TICK_W(TW), .SERIAL_W(W)) u_cell (
                .clk(clk), .rst_n(rst_n), .run(run), .apply(sig_apply[g]),
                .cfg_type(nx[(B + chip_pkg::F_SIG_CTRL)*8 +: 3]),
                .cfg_idle_level(nx[(B + chip_pkg::F_SIG_CTRL)*8 + 3]),
                .cfg_msb_first(nx[(B + chip_pkg::F_SIG_CTRL)*8 + 4]),
                .cfg_delay(nx[(B + chip_pkg::F_SIG_DELAY)*8 +: TW]),
                .cfg_param_a(nx[(B + chip_pkg::F_SIG_PARAM_A)*8 +: TW]),
                .cfg_param_b(nx[(B + chip_pkg::F_SIG_PARAM_B)*8 +: TW]),
                .cfg_cycles(nx[(B + chip_pkg::F_SIG_CYCLES)*8 +: TW]),
                .cfg_bits(nx[(B + chip_pkg::F_SIG_BITS)*8 +: TW]),
                .cfg_data(nx[(B + chip_pkg::F_SIG_DATA)*8 +: W]),
                .shift_strobe(strobe),
                .pin_out(pin_out[g]), .rising_edge(sig_rise[g]), .falling_edge(sig_fall[g]),
                .active(), .done(sig_done[g]));
        end
    endgenerate
    assign chip_out = pin_out;   // straight from each cell's output register

    // ---- 2-FF sync on the chip outputs (CLAUDE.md §8) ----
    logic [NC-1:0] in_s0, in_s1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin in_s0 <= '0; in_s1 <= '0; end
        else begin in_s0 <= chip_in; in_s1 <= in_s0; end
    end

    // ---- one cap cell per chip output ----
    generate
        for (g = 0; g < NC; g++) begin : g_cap
            localparam int B  = chip_pkg::CAP_BLOCK[g];
            localparam int CW = chip_pkg::CAP_W[g];
            wire strobe;
            wire [CW-1:0] creg;
            if (g == chip_pkg::PISO_CELL) begin : g_strobe
                assign strobe = chip_pkg::PISO_ON_FALLING ? sig_fall[chip_pkg::PISO_CLK_CELL]
                                                          : sig_rise[chip_pkg::PISO_CLK_CELL];
            end else begin : g_no_strobe
                assign strobe = 1'b0;
            end
            cap_cell #(.TICK_W(TW), .CAP_W(CW)) u_cell (
                .clk(clk), .rst_n(rst_n), .run(run), .apply(cap_apply[g]), .sync_in(in_s1[g]),
                .cfg_mode(nx[(B + chip_pkg::F_CAP_CTRL)*8 +: 2]),
                .cfg_msb_first(nx[(B + chip_pkg::F_CAP_CTRL)*8 + 2]),
                .cfg_bits(nx[(B + chip_pkg::F_CAP_BITS)*8 +: TW]), .capture_strobe(strobe),
                .level_out(cap_level[g]), .edge_count(cap_edges[g*TW +: TW]),
                .period_ticks(cap_period[g*TW +: TW]), .high_ticks(cap_high[g*TW +: TW]),
                .period_valid(), .capture_reg(creg), .done(cap_done[g]));
            if (CW == CB * 8) begin : g_full
                assign cap_reg[g] = creg;
            end else begin : g_ext
                assign cap_reg[g] = {{(CB * 8 - CW){1'b0}}, creg};
            end
        end
    endgenerate

    logic [SW-1:0] shown;
    assign shown    = busy ? step : last_step;
    assign led[2:0] = shown[2:0];
    assign led[3]   = busy;
    assign led[4]   = seq_done;
    assign led[5]   = fault;
    assign led[6]   = late;
    assign led[7]   = link_error;

endmodule
