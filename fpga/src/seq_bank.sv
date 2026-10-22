`timescale 1ns / 1ps
//==========================================================================
// seq_bank
//
// Phase 7 round 2: the step table for seq_engine when it is written over
// the link instead of compiled in. Two parts:
//
//   * Table RAM: 2**STEP_W steps x ENTRY_BYTES bytes, written one byte at a
//     time from the link (wr_*). Stored as 4 byte-lanes of
//     (2**STEP_W * ENTRY_BYTES / 4) words, each with a registered read, so
//     it infers block RAM and the copy below reads 4 bytes per tick.
//   * Next bank: registers holding ONE step's entry (the first USED_BYTES
//     bytes), copied out of the RAM for `fetch_step` while the engine runs
//     the current step. The cells' cfg_* inputs come from here (they only
//     latch on an APPLY), and so does the engine's view of the step header
//     on an apply tick. fetch_ready = the bank holds fetch_step's entry.
//     A copy takes ceil(USED_BYTES/4) + 2 ticks (39 for the Phase 7 loopback
//     layout); a step shorter than that makes the engine wait (LATE).
//
// hdr = the header (first HDR_BYTES bytes) of the CURRENT step: on an
// apply tick it is the next bank's (the step being applied), afterwards a
// copy taken on that tick, so it stays valid while the bank is refilled
// with the step after.
//
// Byte layout of an entry: tools/nemo_ctl/sequence.py (entry_layout); the
// generated phase7_link_pkg carries the offsets. Writes invalidate the bank
// (it re-copies), so a table rewritten while idle is always picked up; the
// top only allows table writes while the engine is idle.
//==========================================================================
module seq_bank #(
    parameter int STEP_W      = 4,
    parameter int ENTRY_BYTES = 256,  // address stride per step, power of 2, multiple of 4
    parameter int USED_BYTES  = 148,  // bytes of each entry actually copied
    parameter int HDR_BYTES   = 12,
    localparam int TABLE_AW   = STEP_W + $clog2(ENTRY_BYTES)
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    wr_en,         // table write, byte address within the table
    input  logic [TABLE_AW-1:0]     wr_addr,
    input  logic [7:0]              wr_data,

    input  logic [STEP_W-1:0]       fetch_step,
    output logic                    fetch_ready,
    input  logic                    apply_tick,

    output logic [USED_BYTES*8-1:0] next_entry,
    output logic [HDR_BYTES*8-1:0]  hdr
);

    localparam int WORDS_PER_ENTRY = ENTRY_BYTES / 4;
    localparam int DEPTH           = (2 ** STEP_W) * WORDS_PER_ENTRY;
    localparam int WAW             = $clog2(DEPTH);
    localparam int NW              = (USED_BYTES + 3) / 4;   // words copied per fetch
    localparam int WIW             = $clog2(NW + 1);

    // ---- table RAM, 4 byte lanes ----
    logic [7:0] lane0 [0:DEPTH-1];
    logic [7:0] lane1 [0:DEPTH-1];
    logic [7:0] lane2 [0:DEPTH-1];
    logic [7:0] lane3 [0:DEPTH-1];
    logic [WAW-1:0] wr_word;
    assign wr_word = wr_addr[TABLE_AW-1:2];

    logic           rd_en;
    logic [WAW-1:0] rd_word;
    logic [31:0]    rd_data;      // registered read: valid the tick after rd_en

    always_ff @(posedge clk) begin
        if (wr_en && wr_addr[1:0] == 2'd0) lane0[wr_word] <= wr_data;
        if (wr_en && wr_addr[1:0] == 2'd1) lane1[wr_word] <= wr_data;
        if (wr_en && wr_addr[1:0] == 2'd2) lane2[wr_word] <= wr_data;
        if (wr_en && wr_addr[1:0] == 2'd3) lane3[wr_word] <= wr_data;
        if (rd_en) rd_data <= {lane3[rd_word], lane2[rd_word], lane1[rd_word], lane0[rd_word]};
    end

    // ---- copy one entry into the next bank ----
    logic              valid;      // next_entry holds `loaded`'s entry
    logic [STEP_W-1:0] loaded;
    logic              copying;
    logic [STEP_W-1:0] cp_step;
    logic [WIW-1:0]    issue_w;    // next word to read
    logic              st_pend;    // rd_data holds word st_w
    logic [WIW-1:0]    st_w;
    logic [WIW-1:0]    stored;     // words stored so far

    assign fetch_ready = valid && !copying && (loaded == fetch_step);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid      <= 1'b0;
            loaded     <= '0;
            copying    <= 1'b0;
            cp_step    <= '0;
            issue_w    <= '0;
            st_pend    <= 1'b0;
            st_w       <= '0;
            stored     <= '0;
            rd_en      <= 1'b0;
            rd_word    <= '0;
            next_entry <= '0;
        end else begin
            rd_en   <= 1'b0;
            st_pend <= rd_en;
            st_w    <= issue_w - 1'b1;   // the word whose read was issued last tick

            if (wr_en || (copying && fetch_step != cp_step)) begin
                // table changed, or the engine wants another step: (re)start the copy
                valid   <= 1'b0;
                copying <= 1'b1;
                cp_step <= fetch_step;
                issue_w <= '0;
                stored  <= '0;
                st_pend <= 1'b0;
            end else if (!copying && !(valid && loaded == fetch_step)) begin
                valid   <= 1'b0;
                copying <= 1'b1;
                cp_step <= fetch_step;
                issue_w <= '0;
                stored  <= '0;
                st_pend <= 1'b0;
            end else if (copying) begin
                if (issue_w < NW) begin
                    rd_en   <= 1'b1;
                    rd_word <= WAW'(cp_step) * WAW'(WORDS_PER_ENTRY) + WAW'(issue_w);
                    issue_w <= issue_w + 1'b1;
                end
                if (st_pend) begin
                    for (int b = 0; b < 4; b++)
                        if (int'(st_w) * 4 + b < USED_BYTES)
                            next_entry[(int'(st_w) * 4 + b) * 8 +: 8] <= rd_data[b * 8 +: 8];
                    stored <= stored + 1'b1;
                    if (stored == NW - 1) begin
                        copying <= 1'b0;
                        valid   <= 1'b1;
                        loaded  <= cp_step;
                    end
                end
            end
        end
    end

    // ---- header of the current step ----
    logic [HDR_BYTES*8-1:0] cur_hdr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          cur_hdr <= '0;
        else if (apply_tick) cur_hdr <= next_entry[HDR_BYTES*8-1:0];
    end
    assign hdr = apply_tick ? next_entry[HDR_BYTES*8-1:0] : cur_hdr;

endmodule
