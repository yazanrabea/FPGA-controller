`timescale 1ns / 1ps
//==========================================================================
// link_ctrl
//
// Phase 5 runtime link: parses the framed protocol from docs/link_register_map.md
// off a byte stream (from uart_rx.sv), drives a register file backing 5
// sig_cell + 5 cap_cell instances (the same test pairs as Phase 4's
// phase4_loopback_top.sv), and sends response frames back out (via
// uart_tx.sv) for the commands that need one.
//
// Frame: SOF(0xAA) CMD ADDR_LO ADDR_HI LEN DATA[LEN] CHECKSUM(XOR of
// CMD..DATA). A bad checksum, or an unimplemented CMD (currently just
// LOAD_MODE), gets an explicit NACK response (CMD=0xFF, LEN=0) rather than
// being silently dropped.
//
// Two independent always_ff blocks: one parses incoming bytes and reacts
// (writing the register file, pulsing run_set/run_clear/apply_cmd, or
// staging a response), the other drains any staged response out through
// uart_tx one byte at a time. They hand off through resp_*/resp_start so a
// new incoming frame can start arriving while a previous response is still
// being transmitted.
//==========================================================================
module link_ctrl #(
    parameter int N_SIG = 5,
    parameter int N_CAP = 5,
    parameter int MAX_PAYLOAD = 128   // bytes; covers the whole 120 B capture region in one frame
) (
    input  logic clk,
    input  logic rst_n,

    // from uart_rx
    input  logic [7:0] rx_byte,
    input  logic       rx_byte_valid,

    // to uart_tx
    output logic [7:0] tx_byte,
    output logic        tx_send,
    input  logic        tx_busy,

    // run_ctrl
    output logic run_set,
    output logic run_clear,
    output logic apply_cmd,
    input  logic run,

    // sig_cell shadow config, one set of signals per cell (N_SIG cells)
    output logic [2:0]  sig_cfg_type[N_SIG],
    output logic         sig_cfg_idle_level[N_SIG],
    output logic         sig_cfg_msb_first[N_SIG],
    output logic [31:0] sig_cfg_delay[N_SIG],
    output logic [31:0] sig_cfg_param_a[N_SIG],
    output logic [31:0] sig_cfg_param_b[N_SIG],
    output logic [31:0] sig_cfg_cycles[N_SIG],
    output logic [15:0] sig_cfg_data[N_SIG],
    output logic [31:0] sig_cfg_bits[N_SIG],

    // cap_cell shadow config
    output logic [1:0]  cap_cfg_mode[N_CAP],
    output logic         cap_cfg_msb_first[N_CAP],
    output logic [31:0] cap_cfg_bits[N_CAP],

    // cap_cell live status/results (read-only from the link's point of view)
    input  logic         cap_level_out[N_CAP],
    input  logic         cap_period_valid[N_CAP],
    input  logic         cap_done[N_CAP],
    input  logic [31:0] cap_edge_count[N_CAP],
    input  logic [31:0] cap_period_ticks[N_CAP],
    input  logic [31:0] cap_high_ticks[N_CAP],
    input  logic [15:0] cap_capture_reg[N_CAP]
);

    localparam logic [7:0] SOF = 8'hAA;
    localparam logic [7:0] CMD_WRITE_REG     = 8'h01;
    localparam logic [7:0] CMD_READ_REG      = 8'h02;
    localparam logic [7:0] CMD_LOAD_MODE     = 8'h03;
    localparam logic [7:0] CMD_APPLY         = 8'h04;
    localparam logic [7:0] CMD_RUN           = 8'h05;
    localparam logic [7:0] CMD_STOP          = 8'h06;
    localparam logic [7:0] CMD_STATUS        = 8'h07;
    localparam logic [7:0] CMD_READ_CAPTURE  = 8'h08;
    localparam logic [7:0] CMD_NACK          = 8'hFF;

    localparam int SIG_BASE     = 16'h0010;
    localparam int SIG_STRIDE   = 24;
    localparam int CAP_BASE     = 16'h0100;
    localparam int CAP_STRIDE   = 24;
    localparam int REG_BYTES    = CAP_BASE + N_CAP * CAP_STRIDE;  // size of the backing array

    // ---- the flat byte-addressable backing store for every WRITABLE field
    //      (global SCRATCH/RUN_CTRL/APPLY_CTRL, every sig_cell field, and
    //      every cap_cell's CTRL/BITS). Read-only cap_cell status/results
    //      bytes are never stored here -- reads to those addresses are
    //      intercepted in read_byte() below and answer from the live
    //      cap_*[] inputs instead, so this array never goes stale for them.
    logic [7:0] regs[0:REG_BYTES-1];

    // ---- assemble each cell's cfg_* ports from the backing store ----
    genvar gi;
    generate
        for (gi = 0; gi < N_SIG; gi = gi + 1) begin : g_sig_wire
            localparam int B = SIG_BASE + SIG_STRIDE * gi;
            assign sig_cfg_type[gi]        = regs[B][2:0];
            assign sig_cfg_idle_level[gi]  = regs[B][3];
            assign sig_cfg_msb_first[gi]   = regs[B][4];
            assign sig_cfg_delay[gi]       = {regs[B+4], regs[B+3], regs[B+2], regs[B+1]};
            assign sig_cfg_param_a[gi]     = {regs[B+8], regs[B+7], regs[B+6], regs[B+5]};
            assign sig_cfg_param_b[gi]     = {regs[B+12], regs[B+11], regs[B+10], regs[B+9]};
            assign sig_cfg_cycles[gi]      = {regs[B+16], regs[B+15], regs[B+14], regs[B+13]};
            assign sig_cfg_data[gi]        = {regs[B+18], regs[B+17]};
            assign sig_cfg_bits[gi]        = {regs[B+22], regs[B+21], regs[B+20], regs[B+19]};
        end
        for (gi = 0; gi < N_CAP; gi = gi + 1) begin : g_cap_wire
            localparam int B = CAP_BASE + CAP_STRIDE * gi;
            assign cap_cfg_mode[gi]       = regs[B][1:0];
            assign cap_cfg_msb_first[gi]  = regs[B][2];
            assign cap_cfg_bits[gi]       = {regs[B+4], regs[B+3], regs[B+2], regs[B+1]};
        end
    endgenerate

    // ---- combinational read with the read-only intercepts ----
    function automatic logic [7:0] read_byte(logic [15:0] addr);
        int k;
        int off;
        if (addr == 16'h0001) return {7'b0, run};
        if (addr == 16'h0002) return 8'h00;
        if (addr == 16'h0003) return {7'b0, run};
        if (addr >= CAP_BASE && addr < CAP_BASE + N_CAP * CAP_STRIDE) begin
            k   = (addr - CAP_BASE) / CAP_STRIDE;
            off = (addr - CAP_BASE) % CAP_STRIDE;
            case (off)
                5:  return {5'b0, cap_done[k], cap_period_valid[k], cap_level_out[k]};
                6:  return cap_edge_count[k][7:0];
                7:  return cap_edge_count[k][15:8];
                8:  return cap_edge_count[k][23:16];
                9:  return cap_edge_count[k][31:24];
                10: return cap_period_ticks[k][7:0];
                11: return cap_period_ticks[k][15:8];
                12: return cap_period_ticks[k][23:16];
                13: return cap_period_ticks[k][31:24];
                14: return cap_high_ticks[k][7:0];
                15: return cap_high_ticks[k][15:8];
                16: return cap_high_ticks[k][23:16];
                17: return cap_high_ticks[k][31:24];
                18: return cap_capture_reg[k][7:0];
                19: return cap_capture_reg[k][15:8];
                default: return (addr < REG_BYTES) ? regs[addr] : 8'h00;
            endcase
        end
        return (addr < REG_BYTES) ? regs[addr] : 8'h00;
    endfunction

    // ---- RX frame parser / dispatcher ----
    typedef enum logic [3:0] {
        WAIT_SOF, GET_CMD, GET_ADDR_LO, GET_ADDR_HI, GET_LEN, GET_DATA, GET_CKSUM, DISPATCH
    } rx_state_t;
    rx_state_t rx_state;

    logic [7:0]  cmd_reg;
    logic [15:0] addr_reg;
    logic [7:0]  len_reg;
    logic [7:0]  data_buf[0:MAX_PAYLOAD-1];
    logic [7:0]  data_idx;
    logic [7:0]  cksum_calc;

    // handoff to the response sender
    logic         resp_start;
    logic [7:0]  resp_cmd;
    logic [15:0] resp_addr;
    logic [7:0]  resp_len;
    logic [7:0]  resp_data[0:MAX_PAYLOAD-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state   <= WAIT_SOF;
            cmd_reg    <= '0;
            addr_reg   <= '0;
            len_reg    <= '0;
            data_idx   <= '0;
            cksum_calc <= '0;
            run_set    <= 1'b0;
            run_clear  <= 1'b0;
            apply_cmd  <= 1'b0;
            resp_start <= 1'b0;
            resp_cmd   <= '0;
            resp_addr  <= '0;
            resp_len   <= '0;
            for (int i = 0; i < REG_BYTES; i++) regs[i] <= 8'h00;
        end else begin
            run_set    <= 1'b0;
            run_clear  <= 1'b0;
            apply_cmd  <= 1'b0;
            resp_start <= 1'b0;

            case (rx_state)
                WAIT_SOF: begin
                    if (rx_byte_valid && rx_byte == SOF) rx_state <= GET_CMD;
                end
                GET_CMD: if (rx_byte_valid) begin
                    cmd_reg    <= rx_byte;
                    cksum_calc <= rx_byte;
                    rx_state   <= GET_ADDR_LO;
                end
                GET_ADDR_LO: if (rx_byte_valid) begin
                    addr_reg[7:0] <= rx_byte;
                    cksum_calc    <= cksum_calc ^ rx_byte;
                    rx_state      <= GET_ADDR_HI;
                end
                GET_ADDR_HI: if (rx_byte_valid) begin
                    addr_reg[15:8] <= rx_byte;
                    cksum_calc     <= cksum_calc ^ rx_byte;
                    rx_state       <= GET_LEN;
                end
                GET_LEN: if (rx_byte_valid) begin
                    len_reg    <= rx_byte;
                    cksum_calc <= cksum_calc ^ rx_byte;
                    data_idx   <= '0;
                    if (rx_byte == 8'h00) rx_state <= GET_CKSUM;
                    else rx_state <= GET_DATA;
                end
                GET_DATA: if (rx_byte_valid) begin
                    data_buf[data_idx] <= rx_byte;
                    cksum_calc         <= cksum_calc ^ rx_byte;
                    if (data_idx == len_reg - 1'b1) rx_state <= GET_CKSUM;
                    data_idx <= data_idx + 1'b1;
                end
                GET_CKSUM: if (rx_byte_valid) begin
                    if (rx_byte == cksum_calc) begin
                        rx_state <= DISPATCH;
                    end else begin
                        resp_cmd   <= CMD_NACK;
                        resp_addr  <= '0;
                        resp_len   <= '0;
                        resp_start <= 1'b1;
                        rx_state   <= WAIT_SOF;
                    end
                end
                DISPATCH: begin
                    rx_state <= WAIT_SOF;
                    case (cmd_reg)
                        CMD_WRITE_REG: begin
                            for (int i = 0; i < MAX_PAYLOAD; i++) begin
                                if (i < len_reg && (addr_reg + i) < REG_BYTES) begin
                                    regs[addr_reg + i] <= data_buf[i];
                                    if (addr_reg + i == 16'h0001)
                                        {run_clear, run_set} <= data_buf[i][0] ? 2'b01 : 2'b10;
                                    if (addr_reg + i == 16'h0002)
                                        apply_cmd <= 1'b1;
                                end
                            end
                        end
                        CMD_READ_REG: begin
                            resp_cmd  <= CMD_READ_REG;
                            resp_addr <= addr_reg;
                            resp_len  <= len_reg;
                            for (int i = 0; i < MAX_PAYLOAD; i++)
                                resp_data[i] <= (i < len_reg) ? read_byte(addr_reg + i) : 8'h00;
                            resp_start <= 1'b1;
                        end
                        CMD_APPLY: apply_cmd <= 1'b1;
                        CMD_RUN:   run_set   <= 1'b1;
                        CMD_STOP:  run_clear <= 1'b1;
                        CMD_STATUS: begin
                            resp_cmd     <= CMD_STATUS;
                            resp_addr    <= 16'h0003;
                            resp_len     <= 8'd1;
                            resp_data[0] <= read_byte(16'h0003);
                            resp_start   <= 1'b1;
                        end
                        CMD_READ_CAPTURE: begin
                            resp_cmd  <= CMD_READ_CAPTURE;
                            resp_addr <= addr_reg;
                            resp_len  <= len_reg;
                            for (int i = 0; i < MAX_PAYLOAD; i++)
                                resp_data[i] <= (i < len_reg) ? read_byte(CAP_BASE + addr_reg + i) : 8'h00;
                            resp_start <= 1'b1;
                        end
                        default: begin  // CMD_LOAD_MODE (unimplemented) or anything unknown
                            resp_cmd   <= CMD_NACK;
                            resp_addr  <= '0;
                            resp_len   <= '0;
                            resp_start <= 1'b1;
                        end
                    endcase
                end
                default: rx_state <= WAIT_SOF;
            endcase
        end
    end

    // ---- response sender ----
    typedef enum logic [3:0] {
        S_IDLE, S_SOF, S_CMD, S_ADDR_LO, S_ADDR_HI, S_LEN, S_DATA, S_CKSUM
    } tx_state_t;
    tx_state_t tx_state;

    logic [7:0]  s_cmd;
    logic [15:0] s_addr;
    logic [7:0]  s_len;
    logic [7:0]  s_data[0:MAX_PAYLOAD-1];
    logic [7:0]  s_idx;
    logic [7:0]  s_cksum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= S_IDLE;
            tx_send  <= 1'b0;
            tx_byte  <= '0;
            s_idx    <= '0;
            s_cksum  <= '0;
        end else begin
            tx_send <= 1'b0;

            case (tx_state)
                S_IDLE: begin
                    if (resp_start) begin
                        s_cmd   <= resp_cmd;
                        s_addr  <= resp_addr;
                        s_len   <= resp_len;
                        for (int i = 0; i < MAX_PAYLOAD; i++) s_data[i] <= resp_data[i];
                        tx_state <= S_SOF;
                    end
                end
                S_SOF: if (!tx_busy) begin
                    tx_byte  <= SOF;
                    tx_send  <= 1'b1;
                    tx_state <= S_CMD;
                end
                S_CMD: if (!tx_busy && !tx_send) begin
                    tx_byte  <= s_cmd;
                    tx_send  <= 1'b1;
                    s_cksum  <= s_cmd;
                    tx_state <= S_ADDR_LO;
                end
                S_ADDR_LO: if (!tx_busy && !tx_send) begin
                    tx_byte  <= s_addr[7:0];
                    tx_send  <= 1'b1;
                    s_cksum  <= s_cksum ^ s_addr[7:0];
                    tx_state <= S_ADDR_HI;
                end
                S_ADDR_HI: if (!tx_busy && !tx_send) begin
                    tx_byte  <= s_addr[15:8];
                    tx_send  <= 1'b1;
                    s_cksum  <= s_cksum ^ s_addr[15:8];
                    tx_state <= S_LEN;
                end
                S_LEN: if (!tx_busy && !tx_send) begin
                    tx_byte  <= s_len;
                    tx_send  <= 1'b1;
                    s_cksum  <= s_cksum ^ s_len;
                    s_idx    <= '0;
                    if (s_len == 8'h00) tx_state <= S_CKSUM;
                    else tx_state <= S_DATA;
                end
                S_DATA: if (!tx_busy && !tx_send) begin
                    tx_byte  <= s_data[s_idx];
                    tx_send  <= 1'b1;
                    s_cksum  <= s_cksum ^ s_data[s_idx];
                    if (s_idx == s_len - 1'b1) tx_state <= S_CKSUM;
                    s_idx <= s_idx + 1'b1;
                end
                S_CKSUM: if (!tx_busy && !tx_send) begin
                    tx_byte  <= s_cksum;
                    tx_send  <= 1'b1;
                    tx_state <= S_IDLE;
                end
                default: tx_state <= S_IDLE;
            endcase
        end
    end

endmodule
