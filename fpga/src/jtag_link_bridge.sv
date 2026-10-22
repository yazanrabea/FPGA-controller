`timescale 1ns / 1ps
//==========================================================================
// jtag_link_bridge
//
// JTAG link step J2 (docs/decisions.md: PC link = JTAG over J17). Carries the
// link's byte stream over BSCANE2 user-register scans instead of a UART, and
// gives link_frame.sv the same byte ports as uart_rx / uart_tx. The BSCANE2
// primitive itself is in jtag_link_bscan.sv, so this module simulates
// without unisims (fpga/tb/jtag_link_bridge_tb.sv).
//
// Every scan is exactly DR_BITS bits (EXP-05: the ARM DAP's bypass bit makes
// short scans misaligned). Byte i of a scan = bits [8i+7:8i], shifted LSB
// first (xsdb's -hex strings are byte-little-endian).
//
//   PC -> FPGA (TDI, used at Update)      FPGA -> PC (TDO, loaded at Capture)
//   B0,B1  magic 4A 4C ("JL")             B0,B1  magic 6A 6C ("jl")
//   B2     n_dn, data bytes (<= MAXD)     B2     flags: [0] ready, [1] dn_overflow (sticky)
//   B3     0                              B3     n_up, data bytes offered (<= MAXU)
//   B4..   down data (MAXD = NB-4)        B4     free: down FIFO space (saturates at 255)
//                                         B5     accepted-scan counter (wraps)
//                                         B6,B7  0
//                                         B8..   up data (MAXU = NB-8)
//
// Protocol (the PC side is tools/nemo_ctl, step J4):
//   * A scan is ACCEPTED iff its own Capture showed ready=1 (latched at
//     Capture) and its header is valid at Update. So the PC knows from the
//     scan it just did whether it was accepted, and any other scan (hw_server
//     probing, a tool with garbage, EXP-05) changes nothing: no magic.
//   * Acceptance is the acknowledgement: when a scan is accepted, the n_up
//     bytes offered in that same scan's Capture are dropped from the up FIFO.
//     Not accepted: nothing is consumed, the PC sends the same down bytes again.
//   * The PC sends at most (free - n_dn of its last accepted scan) down bytes,
//     using the last ready Capture; extra bytes are dropped and set dn_overflow.
//
// Clock crossing (TCK <-> clk), by handshake, never by shared counters:
//   accepted Update: h <= sr, h_tog flips, tck_wait = 1 (TCK domain)
//   clk sees h_tog (3-FF sync): pushes h's down bytes into the down FIFO, drops
//     the offered up bytes, builds the next reply `u` byte by byte, flips p_tog
//   TCK sees p_tog (2-FF sync): tck_wait = 0. While tck_wait, Capture forces
//     ready = 0, so `u` is only ever loaded while clk isn't writing it, and `h`
//     is only overwritten after clk is done reading it.
//   Turnaround ~ (n_dn + MAXU + 10) clk cycles, ~3 us; xsdb scans are ~1.3 ms
//   apart, so a polling PC always finds ready = 1.
//
// System side: down bytes leave on rx_byte/rx_byte_valid at most one per
// RX_GAP clk cycles (link_frame's 16-byte input FIFO doesn't fill during a
// long register write); up bytes enter through tx_byte/tx_send, tx_busy =
// up FIFO full (link_frame waits on it, as on uart_tx).
//==========================================================================
module jtag_link_bridge #(
    parameter int DR_BITS = 1024,   // scan length, multiple of 8, <= 2048 (byte fields are 8-bit)
    parameter int FIFO_AW = 8,      // down / up FIFO depth = 2**FIFO_AW bytes
    parameter int RX_GAP  = 32      // clk cycles between down bytes handed to link_frame
) (
    // ---- TAP side, from BSCANE2 (TCK domain) ----
    input  logic       tck,
    input  logic       sel,
    input  logic       capture,
    input  logic       shift,
    input  logic       update,
    input  logic       tdi,
    output logic       tdo,

    // ---- system side (clk domain), same shape as uart_rx / uart_tx ----
    input  logic       clk,
    input  logic       rst_n,
    output logic [7:0] rx_byte,
    output logic       rx_byte_valid,
    input  logic [7:0] tx_byte,
    input  logic       tx_send,
    output logic       tx_busy,
    output logic       dn_overflow     // sticky: the PC sent more than `free`
);
    localparam int NB    = DR_BITS / 8;
    localparam int MAXD  = NB - 4;
    localparam int MAXU  = NB - 8;
    localparam int DEPTH = 2 ** FIFO_AW;
    localparam logic [7:0] MAG_DN0 = 8'h4A, MAG_DN1 = 8'h4C;
    localparam logic [7:0] MAG_UP0 = 8'h6A, MAG_UP1 = 8'h6C;

    // ======================= TCK domain =======================
    // No reset (the TAP's reset doesn't reach user logic): declaration values are
    // the power-up values. tck_wait starts at 1 until clk publishes the first reply.
    logic [DR_BITS-1:0] sr          = '0;   // the scan register
    logic [DR_BITS-1:0] h           = '0;   // last accepted scan, for the clk side
    logic               h_tog       = 1'b0;
    logic               tck_wait    = 1'b1;
    logic               will_accept = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic p_s0 = 1'b0, p_s1 = 1'b0;
    logic               p_seen      = 1'b0;

    logic [DR_BITS-1:0] u;                  // reply, written by clk only while tck_wait
    logic               p_tog;              // clk: flips after each reply is complete

    logic valid_hdr;
    assign valid_hdr = (sr[7:0] == MAG_DN0) && (sr[15:8] == MAG_DN1) && (sr[23:16] <= MAXD);

    assign tdo = sr[0];

    always_ff @(posedge tck) begin
        p_s0 <= p_tog;
        p_s1 <= p_s0;
        if (p_s1 != p_seen) begin            // clk finished the last handoff
            p_seen   <= p_s1;
            tck_wait <= 1'b0;
        end

        if (sel && capture) begin
            sr          <= {u[DR_BITS-1:17], u[16] & ~tck_wait, u[15:0]};   // B2 bit0 = ready
            will_accept <= !tck_wait;
        end else if (sel && shift) begin
            sr <= {tdi, sr[DR_BITS-1:1]};
        end

        if (sel && update && will_accept && valid_hdr) begin
            h           <= sr;
            h_tog       <= ~h_tog;
            tck_wait    <= 1'b1;             // overrides a same-edge clear above
            will_accept <= 1'b0;
        end
    end

    // ======================= clk domain =======================
    (* ASYNC_REG = "TRUE" *) logic h_s0, h_s1;
    logic h_s2, h_edge;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) {h_s0, h_s1, h_s2} <= '0;
        else        {h_s0, h_s1, h_s2} <= {h_tog, h_s0, h_s1};
    end
    assign h_edge = h_s1 ^ h_s2;

    // FIFOs (single clock: both ends in clk)
    logic [7:0]         dmem [0:DEPTH-1];
    logic [7:0]         umem [0:DEPTH-1];
    logic [FIFO_AW-1:0] d_wr, d_rd, u_wr, u_rd;
    logic [FIFO_AW:0]   d_cnt, u_cnt;

    typedef enum logic [2:0] { C_INIT, C_IDLE, C_PUSH, C_BUILD, C_PUB } cstate_t;
    cstate_t cst;
    logic [7:0] idx;        // byte index within the current step
    logic [7:0] n_dn_r;     // down bytes in the scan being processed
    logic [7:0] u_n;        // up bytes offered in the current reply
    logic [7:0] n_acc;      // accepted scans
    logic [$clog2(RX_GAP+1)-1:0] gap;

    assign tx_busy = (u_cnt == DEPTH);

    logic d_push, d_pop, u_push;
    logic [7:0] d_push_byte;
    assign u_push = tx_send && !tx_busy;
    assign d_pop  = (gap == 0) && (d_cnt != 0);
    // C_PUSH copies one down byte per cycle; a full FIFO drops it (dn_overflow).
    // A pop in the same cycle only makes room for the NEXT byte (conservative).
    assign d_push      = (cst == C_PUSH) && (idx != n_dn_r) && (d_cnt != DEPTH);
    assign d_push_byte = h[(4 + idx) * 8 +: 8];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst           <= C_INIT;
            idx           <= '0;
            n_dn_r        <= '0;
            u_n           <= '0;
            n_acc         <= '0;
            p_tog         <= 1'b0;
            u             <= '0;
            dn_overflow   <= 1'b0;
            d_wr <= '0; d_rd <= '0; d_cnt <= '0;
            u_wr <= '0; u_rd <= '0; u_cnt <= '0;
            gap           <= '0;
            rx_byte       <= '0;
            rx_byte_valid <= 1'b0;
        end else begin
            // ---- down FIFO -> link_frame, one byte per RX_GAP cycles ----
            rx_byte_valid <= 1'b0;
            if (d_pop) begin
                rx_byte       <= dmem[d_rd];
                rx_byte_valid <= 1'b1;
                d_rd          <= d_rd + 1'b1;
                gap           <= RX_GAP - 1;
            end else if (gap != 0) begin
                gap <= gap - 1'b1;
            end

            // ---- link_frame -> up FIFO (the byte itself: memory block below) ----
            if (u_push) u_wr <= u_wr + 1'b1;

            // ---- handoff processing ----
            case (cst)
                C_INIT: begin                  // first reply after reset: nothing offered yet
                    idx <= '0;
                    cst <= C_BUILD;
                end
                C_IDLE: if (h_edge) begin      // a scan was accepted: h is stable until we publish
                    n_dn_r <= h[23:16];
                    n_acc  <= n_acc + 1'b1;
                    idx    <= '0;
                    cst    <= C_PUSH;
                end
                C_PUSH: begin
                    if (idx == n_dn_r) begin
                        // the accepted scan's Capture offered u_n bytes: consumed
                        u_rd <= u_rd + FIFO_AW'(u_n);
                        idx  <= '0;
                        cst  <= C_BUILD;
                    end else begin
                        if (d_cnt == DEPTH) dn_overflow <= 1'b1;   // byte dropped (d_push = 0)
                        idx <= idx + 1'b1;
                    end
                end
                C_BUILD: begin
                    // u_cnt / u_rd here already reflect the pop from C_PUSH
                    if (idx < MAXU && idx < u_cnt) begin
                        u[(8 + idx) * 8 +: 8] <= umem[u_rd + FIFO_AW'(idx)];
                        idx <= idx + 1'b1;
                    end else begin
                        u_n                <= idx;
                        u[7:0]             <= MAG_UP0;
                        u[15:8]            <= MAG_UP1;
                        u[23:16]           <= {6'b0, dn_overflow, 1'b1};
                        u[31:24]           <= idx;
                        u[39:32]           <= (DEPTH - d_cnt > 255) ? 8'd255 : 8'(DEPTH - d_cnt);
                        u[47:40]           <= n_acc;
                        u[63:48]           <= '0;
                        cst                <= C_PUB;
                    end
                end
                C_PUB: begin
                    p_tog <= ~p_tog;           // reply complete: the TCK side may load it
                    cst   <= C_IDLE;
                end
                default: cst <= C_IDLE;
            endcase

            if (d_push) d_wr <= d_wr + 1'b1;

            d_cnt <= d_cnt + (d_push ? 1'b1 : 1'b0) - (d_pop ? 1'b1 : 1'b0);
            u_cnt <= u_cnt + (u_push ? 1'b1 : 1'b0)
                           - ((cst == C_PUSH && idx == n_dn_r) ? (FIFO_AW + 1)'(u_n) : '0);
        end
    end

    // FIFO memories: written in their own block with no reset, so Vivado infers
    // distributed RAM. Inside the async-reset block above they became 4096 flip-flops
    // (Synth 8-4767), and the 100 MHz slack was only +0.29 ns.
    always_ff @(posedge clk) begin
        if (d_push) dmem[d_wr] <= d_push_byte;
        if (u_push) umem[u_wr] <= tx_byte;
    end

endmodule
