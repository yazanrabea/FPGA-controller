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
//
// Pad readback (verification plan Step 2, 2026-11-02): each output is an IOBUF
// that always drives (T = 0); its input buffer reads the same pad back, through
// a 2-FF synchronizer, into a readback_cell, which records what the pin did
// during the run and keeps it after (edges, saw 0 / 1, period, high, end level).
// The cells' window is RUN delayed by the same 2 ticks. sipo_in's readback is
// also shifted, on the readback of clk_sipo's sampling edge (the edge opposite
// SIPO_ON_FALLING, as the chip samples), into a 136-bit register. All read with
// READ_REG at chip_pkg RB_BASE / RB_INFO / RB_SIPO; the 16-byte stride lets
// the address bits pick the cell (no compare chain). PAD_READBACK = 0 (for
// vchip_top, whose DFT outputs have no pin) reads the output registers instead
// of the pads; RB_INFO +1 tells the PC which.
// What it can't see: an open after the pad (connector, board, wire, chip) and
// analog level / ringing (0/1 at the input buffer's threshold).
//
// Sampler (SAMPLER = 1, decided 2026-11-02 after EXP-11): the sample_cell proven
// in EXP-11 (sample_loopback_top), 32 bits x 4096 samples, armed when a sequence
// starts. A sample = bits 0-21 the 22 outputs as read back (rb_s1: at the pads, or
// the output registers with PAD_READBACK = 0), 22-25 the 4 chip outputs (in_s1),
// 26-29 the step number, 30-31 zero. All three go through 2 FFs, so they line up
// (same SYNC_TICKS = 2 as samples.py). Registers 0x0020-0x0037 as on the loopback
// bench (docs/link_register_map.md "v2 sampler"); samples at 0x8000 + 4 i (the
// step table, write-only, takes 0x1000-0x4FFF here). Both read regions are
// decoded from address bits (the read path has little timing margin, see the
// readback decode); the sample byte is muxed in after the register read, like
// phase7_link_top. SAMPLER = 0 builds nothing extra.
//==========================================================================
module chip_top #(
    parameter bit PAD_READBACK = 1'b1,  // 1: IOBUF readback from the pads; 0: from the output registers
    parameter bit SAMPLER      = 1'b1   // 1: add the 32 x 4096 sample_cell (see header)
) (
    input  logic                     clk,        // 100 MHz ZedBoard system clock
    output logic [7:0]               led,
    inout  wire  [chip_pkg::N_SIG-1:0] chip_out,  // -> chip inputs (DRIVE 4, SLEW SLOW in the XDC); read back
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
    logic [7:0]  reg_rdata;          // the register read; bus_rdata = it or a sample byte (sampler)
    logic [7:0]  rb_byte;            // the readback region's byte at bus_raddr (below)
    logic [7:0]  sreg_byte;          // the sampler register region's byte at bus_raddr (below)
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
            reg_rdata      <= '0;
        end else begin
            if (rx_overflow_jtag || rx_overflow) link_error <= 1'b1;
            if (bus_re) reg_rdata <= in_rb_region(bus_raddr)   ? rb_byte
                                   : in_sreg_region(bus_raddr) ? sreg_byte : read_byte(bus_raddr);
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
    // ---- outputs + pad readback (verification plan Step 2) ----
    wire [NS-1:0] rb_raw;                // what each output pad reads back
    generate
        for (g = 0; g < NS; g++) begin : g_out
            if (PAD_READBACK) begin : g_iobuf
                // always driving (T = 0); O = the pad through its input buffer
                IOBUF u_iobuf (.I(pin_out[g]), .T(1'b0), .O(rb_raw[g]), .IO(chip_out[g]));
            end else begin : g_internal
                assign chip_out[g] = pin_out[g];   // straight from the cell's output register
                assign rb_raw[g]   = pin_out[g];
            end
        end
    endgenerate

    // 2-FF sync (CLAUDE.md §8) and the window: RUN delayed by the same 2 ticks
    logic [NS-1:0] rb_s0, rb_s1;
    logic          rb_run0, rb_run;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rb_s0 <= '0; rb_s1 <= '0; rb_run0 <= 1'b0; rb_run <= 1'b0; end
        else begin rb_s0 <= rb_raw; rb_s1 <= rb_s0; rb_run0 <= run; rb_run <= rb_run0; end
    end

    wire [NS*TW-1:0] rb_edges, rb_period, rb_high;
    wire [NS-1:0]    rb_saw0, rb_saw1, rb_end;
    generate
        for (g = 0; g < NS; g++) begin : g_rb
            readback_cell #(.TICK_W(TW)) u_rb (
                .clk(clk), .rst_n(rst_n), .run(rb_run), .sync_in(rb_s1[g]),
                .edges(rb_edges[g*TW +: TW]), .period(rb_period[g*TW +: TW]), .high(rb_high[g*TW +: TW]),
                .saw0(rb_saw0[g]), .saw1(rb_saw1[g]), .end_level(rb_end[g]));
        end
    endgenerate

    // sipo_in bit-exact: its readback shifted on the readback of clk_sipo's sampling edge
    localparam int SPW = chip_pkg::SIG_SERIAL_W[chip_pkg::SIPO_CELL];   // 136
    logic [SPW-1:0] rb_sipo;
    logic [15:0]    rb_sipo_n;           // bits shifted in this window (saturating)
    logic [TW-1:0]  rb_len;              // window length in ticks (the run as the pins saw it)
    logic           rb_sclk_d, rb_run_d;
    wire rb_sclk  = rb_s1[chip_pkg::SIPO_CLK_CELL];
    wire rb_sedge = chip_pkg::SIPO_ON_FALLING ? (rb_sclk && !rb_sclk_d)    // data on falling -> sample rising
                                              : (!rb_sclk && rb_sclk_d);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rb_sipo <= '0; rb_sipo_n <= '0; rb_len <= '0; rb_sclk_d <= 1'b0; rb_run_d <= 1'b0;
        end else begin
            rb_sclk_d <= rb_sclk;
            rb_run_d  <= rb_run;
            if (rb_run && !rb_run_d) begin                    // window opens: start over
                rb_sipo   <= rb_sedge ? SPW'(rb_s1[chip_pkg::SIPO_CELL]) : '0;
                rb_sipo_n <= rb_sedge ? 16'd1 : 16'd0;
                rb_len    <= 1;
            end else if (rb_run) begin
                if (~rb_len != '0) rb_len <= rb_len + 1'b1;   // saturating
                if (rb_sedge) begin
                    rb_sipo <= {rb_sipo[SPW-2:0], rb_s1[chip_pkg::SIPO_CELL]};   // MSB first, as sent
                    if (rb_sipo_n != 16'hFFFF) rb_sipo_n <= rb_sipo_n + 16'd1;
                end
            end
        end
    end

    // readback region (READ_REG), decoded from address bits only (no compares or
    // subtractions: the read path had no timing margin, the first build with
    // range compares failed by 0.046 ns). The whole region is 0x0200-0x03FF
    // (a[15:9] = 0000001); a[8:4] picks one of 32 records of 16 bytes, a[3:0] the byte:
    //   records 0..21 = the cells (RB_BASE + 16 i), 22 = info (RB_INFO = 0x0360),
    //   24..25 = the sipo_in frame (RB_SIPO = 0x0380, 17 bytes), the rest 0.
    localparam int SPB = (SPW + 7) / 8;                                   // 17 bytes
    localparam int REC_INFO = (chip_pkg::RB_INFO - chip_pkg::RB_BASE) / 16;   // 22
    localparam int REC_SIPO = (chip_pkg::RB_SIPO - chip_pkg::RB_BASE) / 16;   // 24
    // the layout this decode assumes (a wrong one fails elaboration, not the board)
    if (chip_pkg::RB_BASE != 16'h0200 || chip_pkg::RB_STRIDE != 16 || NS > REC_INFO
        || REC_SIPO + (SPB + 15) / 16 > 32)
        $error("chip_top readback: chip_pkg RB_* layout doesn't fit the 0x0200-0x03FF bit decode");

    function automatic logic in_rb_region(input logic [15:0] a);
        return a[15:9] == 7'b0000001;
    endfunction
    // sampler: registers 0x0020-0x003F (a[15:5] = 0x001, byte a[4:0]); samples
    // 0x8000-0xBFFF (a[15:14] = 10, sample a[13:2], byte a[1:0])
    function automatic logic in_sreg_region(input logic [15:0] a);
        return SAMPLER && a[15:5] == 11'b0000_0000_001;
    endfunction
    function automatic logic in_samp_region(input logic [15:0] a);
        return a[15:14] == 2'b10;
    endfunction

    wire [32*128-1:0] rb_recs;            // record k at [k*128 +: 128], byte j at [+ 8 j]
    wire [SPB*8-1:0]  rb_sipo_bytes = {{(SPB * 8 - SPW){1'b0}}, rb_sipo};
    generate
        for (g = 0; g < 32; g++) begin : g_rec
            if (g < NS) begin : g_cell
                assign rb_recs[g*128 +: 128] = {24'h0, rb_high[g*TW +: TW], rb_period[g*TW +: TW],
                                                rb_edges[g*TW +: TW], 5'b0, rb_end[g], rb_saw1[g], rb_saw0[g]};
            end else if (g == REC_INFO) begin : g_info
                assign rb_recs[g*128 +: 128] = {56'h0, rb_len, 8'(SPW), rb_sipo_n,
                                                7'b0, PAD_READBACK, 8'(NS)};   // +0 cells .. +5..8 window
            end else if (g >= REC_SIPO && (g - REC_SIPO) * 16 < SPB) begin : g_sipo
                localparam int LO = (g - REC_SIPO) * 16;                // first frame byte in this record
                localparam int N  = (SPB - LO < 16) ? SPB - LO : 16;
                if (N == 16) begin : g_full
                    assign rb_recs[g*128 +: 128] = rb_sipo_bytes[LO*8 +: 128];
                end else begin : g_part
                    assign rb_recs[g*128 +: 128] = {{(128 - N * 8){1'b0}}, rb_sipo_bytes[LO*8 +: N*8]};
                end
            end else begin : g_zero
                assign rb_recs[g*128 +: 128] = '0;
            end
        end
    endgenerate

    // shift by the address bits with zeros appended (x128 = 7 zeros, x8 = 3 zeros): no
    // multiplier in the index (xsim evaluated `a[3:0]*8` in a part-select too narrowly)
    wire [127:0] rb_rec = 128'(rb_recs >> {bus_raddr[8:4], 7'b0});
    assign rb_byte = 8'(rb_rec >> {bus_raddr[3:0], 3'b0});

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

    // ---- sampler (SAMPLER = 1, see header) ----
    localparam int SN = 32, SD = 4096, SAW = 12;          // bits per sample, depth, log2(depth)
    localparam int STEP_BIT = NS + NC;                     // 26: the step number's lowest bit
    if (SAMPLER && STEP_BIT + SW > SN)
        $error("chip_top sampler: outputs + inputs + step bits don't fit 32 bits");

    logic       samp_mem_q;      // the byte read last tick was a sample byte
    logic [7:0] samp_mem_byte;   // that byte (block RAM output, already 1 tick late)
    assign bus_rdata = samp_mem_q ? samp_mem_byte : reg_rdata;

    generate
        if (SAMPLER) begin : g_sampler
            // config (R/W), defaults: every tick, the whole buffer, trigger at once
            logic [31:0] s_div;
            logic [15:0] s_n, s_pre;
            logic [2:0]  s_trig;
            logic [4:0]  s_tpin;
            logic [7:0]  s_tstep;
            logic        s_apply;    // one tick after a config write: the cell takes it (pending)
            // status
            logic        s_armed, s_triggered, s_done;
            logic [SAW:0] s_n_valid, s_trig_idx;
            logic [31:0] s_trig_count;
            logic [SN-1:0] s_rd_data, s_in;
            logic [SW-1:0] stp_s0, stp_s1;   // the step number, through 2 FFs like the pins
            logic [1:0]    lane_q;

            wire in_swr = (bus_waddr[15:4] == 12'h002) && (bus_waddr[3:0] < 4'd11);   // 0x0020-0x002A
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s_div <= 32'd1; s_n <= 16'(SD); s_pre <= '0; s_trig <= '0; s_tpin <= '0;
                    s_tstep <= '0; s_apply <= 1'b0;
                end else begin
                    s_apply <= bus_we && in_swr;
                    if (bus_we && in_swr) begin
                        case (bus_waddr[3:0])
                            4'd0:  s_div[7:0]   <= bus_wdata;
                            4'd1:  s_div[15:8]  <= bus_wdata;
                            4'd2:  s_div[23:16] <= bus_wdata;
                            4'd3:  s_div[31:24] <= bus_wdata;
                            4'd4:  s_n[7:0]     <= bus_wdata;
                            4'd5:  s_n[15:8]    <= bus_wdata;
                            4'd6:  s_pre[7:0]   <= bus_wdata;
                            4'd7:  s_pre[15:8]  <= bus_wdata;
                            4'd8:  s_trig       <= bus_wdata[2:0];
                            4'd9:  s_tpin       <= bus_wdata[4:0];
                            4'd10: s_tstep      <= bus_wdata;
                            default: ;
                        endcase
                    end
                end
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin stp_s0 <= '0; stp_s1 <= '0; end
                else begin stp_s0 <= step; stp_s1 <= stp_s0; end
            end
            // bits 0-21 outputs (read back, 2 FFs), 22-25 chip outputs (2-FF sync), 26-29 step
            assign s_in = SN'({stp_s1, in_s1, rb_s1});

            sample_cell #(.N(SN), .DEPTH(SD), .TICK_W(32)) u_sample (
                .clk(clk), .rst_n(rst_n), .run(run), .apply(s_apply), .sync_in(s_in),
                .cfg_div(s_div), .cfg_n(s_n[SAW:0]), .cfg_pre(s_pre[SAW:0]),
                .cfg_trig(s_trig), .cfg_trig_pin(s_tpin),
                // "ext" = the start of step s_tstep (step_start is the step's apply cycle)
                .trig_ext(step_start && (8'(step) == s_tstep)),
                .rd_idx(bus_raddr[13:2]), .rd_data(s_rd_data),
                .armed(s_armed), .triggered(s_triggered), .done(s_done),
                .n_valid(s_n_valid), .trig_idx(s_trig_idx), .trig_count(s_trig_count));

            // a sample byte: rd_data arrives 1 tick after bus_re, like the bus wants
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin samp_mem_q <= 1'b0; lane_q <= '0; end
                else begin
                    samp_mem_q <= bus_re && in_samp_region(bus_raddr);
                    lane_q     <= bus_raddr[1:0];
                end
            end
            assign samp_mem_byte = 8'(s_rd_data >> {lane_q, 3'b0});

            // register image, byte k at bits [8k +: 8] (docs/link_register_map.md "v2 sampler")
            wire [32*8-1:0] samp_regs = {
                80'h0,                                      // +22..31 reserved
                8'(SAW), 8'(SN),                            // +21 log2(depth), +20 bits per sample
                s_trig_count,                               // +16..19
                16'(s_trig_idx), 16'(s_n_valid),            // +14..15, +12..13
                {5'b0, s_done, s_triggered, s_armed},       // +11 status
                s_tstep, {3'b0, s_tpin}, {5'b0, s_trig},    // +10, +9, +8
                s_pre, s_n, s_div};                         // +6..7, +4..5, +0..3
            assign sreg_byte = 8'(samp_regs >> {bus_raddr[4:0], 3'b0});
        end else begin : g_no_sampler
            assign samp_mem_q    = 1'b0;
            assign samp_mem_byte = 8'h00;
            assign sreg_byte     = 8'h00;
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
