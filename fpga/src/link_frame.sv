`timescale 1ns / 1ps
//==========================================================================
// link_frame
//
// The framed PC<->FPGA protocol of docs/link_register_map.md, on its own:
// parses frames from a byte stream (uart_rx), turns them into accesses on
// a simple byte-wide register bus, and sends response frames (uart_tx).
// What sits behind the bus is the top's business: Phase 5's register file
// (link_ctrl.sv), Phase 7's register file + step-table RAM
// (phase7_link_top.sv). Split out of link_ctrl.sv in Phase 7 round 2 so
// both use one parser.
//
// Frame: SOF(0xAA) CMD ADDR_LO ADDR_HI LEN DATA[LEN] CHECKSUM (XOR of
// CMD..DATA). A bad checksum, a LEN over MAX_PAYLOAD, LOAD_MODE or an
// unknown CMD gets an explicit NACK (CMD=0xFF, LEN=0).
//
// Register bus (all registered, one byte per tick):
//   write: bus_we high for one tick with bus_waddr/bus_wdata. A WRITE_REG of
//          LEN bytes makes LEN consecutive write ticks, ADDR, ADDR+1, ...
//   read:  bus_re high for one tick with bus_raddr; the slave must present
//          that byte on bus_rdata on the NEXT tick (1-tick latency, so a
//          block RAM can sit behind it). READ_REG reads ADDR.., READ_CAPTURE
//          reads CAP_BASE+ADDR.., STATUS reads STATUS_ADDR (1 byte).
//   APPLY / RUN / STOP: one-tick cmd_apply / cmd_run / cmd_stop strobes.
//
// Writes take LEN ticks after the checksum and reads LEN+1, so incoming
// bytes go through a RX_FIFO-byte FIFO first: the parser takes the next
// byte only when it is ready for one, and nothing is lost while it is busy.
// (At 115200 baud a byte arrives every ~8680 ticks, so the FIFO only ever
// fills when bytes come back to back, as in link_ctrl_tb.) If it does
// overflow, rx_overflow goes high and stays high until reset.
// A response is only built while the transmitter is idle (the parser waits
// otherwise), so a second request can't overwrite a response being sent.
//==========================================================================
module link_frame #(
    parameter int          MAX_PAYLOAD = 128,          // bytes per frame, <= 255
    parameter logic [15:0] CAP_BASE    = 16'h0100,     // READ_CAPTURE offset base
    parameter logic [15:0] STATUS_ADDR = 16'h0003,     // what STATUS returns
    parameter int          RX_FIFO     = 16            // input FIFO depth, power of 2
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [7:0]  rx_byte,       // from uart_rx
    input  logic        rx_byte_valid,
    output logic [7:0]  tx_byte,       // to uart_tx
    output logic        tx_send,
    input  logic        tx_busy,

    output logic        bus_we,
    output logic [15:0] bus_waddr,
    output logic [7:0]  bus_wdata,
    output logic        bus_re,
    output logic [15:0] bus_raddr,
    input  logic [7:0]  bus_rdata,     // valid the tick after bus_re

    output logic        cmd_apply,
    output logic        cmd_run,
    output logic        cmd_stop,
    output logic        rx_overflow    // sticky: a received byte was dropped
);

    localparam logic [7:0] SOF              = 8'hAA;
    localparam logic [7:0] CMD_WRITE_REG    = 8'h01;
    localparam logic [7:0] CMD_READ_REG     = 8'h02;
    localparam logic [7:0] CMD_APPLY        = 8'h04;
    localparam logic [7:0] CMD_RUN          = 8'h05;
    localparam logic [7:0] CMD_STOP         = 8'h06;
    localparam logic [7:0] CMD_STATUS       = 8'h07;
    localparam logic [7:0] CMD_READ_CAPTURE = 8'h08;
    localparam logic [7:0] CMD_NACK         = 8'hFF;

    typedef enum logic [3:0] {
        WAIT_SOF, GET_CMD, GET_ADDR_LO, GET_ADDR_HI, GET_LEN, GET_DATA, GET_CKSUM,
        DISPATCH, DO_WRITE, DO_READ, SEND_NACK
    } rx_state_t;
    rx_state_t rx_state;

    logic [7:0]  cmd_reg;
    logic [15:0] addr_reg;
    logic [7:0]  len_reg;
    logic [7:0]  data_buf [0:MAX_PAYLOAD-1];
    logic [7:0]  data_idx;
    logic [7:0]  cksum_calc;

    // response being built / sent (only touched while the transmitter is idle)
    logic        resp_start;
    logic [7:0]  resp_cmd;
    logic [15:0] resp_addr;
    logic [7:0]  resp_len;
    logic [7:0]  resp_buf [0:MAX_PAYLOAD-1];

    // read pipeline
    logic [15:0] rd_base;
    logic [7:0]  rd_issue;     // next byte index to request
    logic [7:0]  rd_store;     // next byte index to store
    logic        rd_pend;      // bus_rdata holds the byte requested last tick

    logic tx_idle;             // defined by the sender below

    // ---- input FIFO: uart_rx pushes, the parser pops when it can take a byte ----
    localparam int FW = $clog2(RX_FIFO);
    logic [7:0]  fifo [0:RX_FIFO-1];
    logic [FW:0] f_count;
    logic [FW-1:0] f_wr, f_rd;
    logic        in_valid;     // a byte for the parser this tick
    logic [7:0]  in_byte;
    logic        want_byte;    // the parser is in a state that consumes a byte
    assign want_byte = (rx_state == WAIT_SOF) || (rx_state == GET_CMD) || (rx_state == GET_ADDR_LO)
                    || (rx_state == GET_ADDR_HI) || (rx_state == GET_LEN) || (rx_state == GET_DATA)
                    || (rx_state == GET_CKSUM);
    assign in_valid  = want_byte && (f_count != 0);
    assign in_byte   = fifo[f_rd];
    logic can_push;
    assign can_push  = (f_count != RX_FIFO) || in_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_count     <= '0;
            f_wr        <= '0;
            f_rd        <= '0;
            rx_overflow <= 1'b0;
        end else begin
            // a byte fits if there is room, or if one leaves this same tick
            if (rx_byte_valid && can_push) begin
                fifo[f_wr] <= rx_byte;
                f_wr       <= f_wr + 1'b1;
            end
            if (rx_byte_valid && !can_push) rx_overflow <= 1'b1;
            if (in_valid) f_rd <= f_rd + 1'b1;
            f_count <= f_count + ((rx_byte_valid && can_push) ? 1 : 0) - (in_valid ? 1 : 0);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state   <= WAIT_SOF;
            cmd_reg    <= '0;
            addr_reg   <= '0;
            len_reg    <= '0;
            data_idx   <= '0;
            cksum_calc <= '0;
            resp_start <= 1'b0;
            resp_cmd   <= '0;
            resp_addr  <= '0;
            resp_len   <= '0;
            rd_base    <= '0;
            rd_issue   <= '0;
            rd_store   <= '0;
            rd_pend    <= 1'b0;
            bus_we     <= 1'b0;
            bus_waddr  <= '0;
            bus_wdata  <= '0;
            bus_re     <= 1'b0;
            bus_raddr  <= '0;
            cmd_apply  <= 1'b0;
            cmd_run    <= 1'b0;
            cmd_stop   <= 1'b0;
        end else begin
            resp_start <= 1'b0;
            bus_we     <= 1'b0;
            bus_re     <= 1'b0;
            cmd_apply  <= 1'b0;
            cmd_run    <= 1'b0;
            cmd_stop   <= 1'b0;
            rd_pend    <= bus_re;

            case (rx_state)
                WAIT_SOF: if (in_valid && in_byte == SOF) rx_state <= GET_CMD;
                GET_CMD: if (in_valid) begin
                    cmd_reg    <= in_byte;
                    cksum_calc <= in_byte;
                    rx_state   <= GET_ADDR_LO;
                end
                GET_ADDR_LO: if (in_valid) begin
                    addr_reg[7:0] <= in_byte;
                    cksum_calc    <= cksum_calc ^ in_byte;
                    rx_state      <= GET_ADDR_HI;
                end
                GET_ADDR_HI: if (in_valid) begin
                    addr_reg[15:8] <= in_byte;
                    cksum_calc     <= cksum_calc ^ in_byte;
                    rx_state       <= GET_LEN;
                end
                GET_LEN: if (in_valid) begin
                    len_reg    <= in_byte;
                    cksum_calc <= cksum_calc ^ in_byte;
                    data_idx   <= '0;
                    rx_state   <= (in_byte == 8'h00) ? GET_CKSUM : GET_DATA;
                end
                GET_DATA: if (in_valid) begin
                    if (data_idx < MAX_PAYLOAD) data_buf[data_idx] <= in_byte;
                    cksum_calc <= cksum_calc ^ in_byte;
                    if (data_idx == len_reg - 1'b1) rx_state <= GET_CKSUM;
                    data_idx <= data_idx + 1'b1;
                end
                GET_CKSUM: if (in_valid) begin
                    rx_state <= (in_byte == cksum_calc && len_reg <= MAX_PAYLOAD) ? DISPATCH : SEND_NACK;
                end

                DISPATCH: begin
                    case (cmd_reg)
                        CMD_WRITE_REG: begin
                            data_idx <= '0;
                            rx_state <= (len_reg == 8'h00) ? WAIT_SOF : DO_WRITE;
                        end
                        CMD_READ_REG, CMD_READ_CAPTURE, CMD_STATUS: if (tx_idle) begin
                            resp_cmd  <= cmd_reg;
                            resp_addr <= (cmd_reg == CMD_STATUS) ? STATUS_ADDR : addr_reg;
                            resp_len  <= (cmd_reg == CMD_STATUS) ? 8'd1 : len_reg;
                            rd_base   <= (cmd_reg == CMD_STATUS)       ? STATUS_ADDR
                                       : (cmd_reg == CMD_READ_CAPTURE) ? CAP_BASE + addr_reg
                                       :                                 addr_reg;
                            rd_issue  <= '0;
                            rd_store  <= '0;
                            if (cmd_reg != CMD_STATUS && len_reg == 8'h00) begin
                                resp_start <= 1'b1;     // zero-length read: empty response now
                                rx_state   <= WAIT_SOF;
                            end else begin
                                rx_state   <= DO_READ;
                            end
                        end
                        CMD_APPLY: begin cmd_apply <= 1'b1; rx_state <= WAIT_SOF; end
                        CMD_RUN:   begin cmd_run   <= 1'b1; rx_state <= WAIT_SOF; end
                        CMD_STOP:  begin cmd_stop  <= 1'b1; rx_state <= WAIT_SOF; end
                        default:   rx_state <= SEND_NACK;   // LOAD_MODE (reserved) or unknown
                    endcase
                end

                DO_WRITE: begin
                    bus_we    <= 1'b1;
                    bus_waddr <= addr_reg + data_idx;
                    bus_wdata <= data_buf[data_idx];
                    data_idx  <= data_idx + 1'b1;
                    if (data_idx == len_reg - 1'b1) rx_state <= WAIT_SOF;
                end

                DO_READ: begin
                    if (rd_issue != resp_len) begin
                        bus_re    <= 1'b1;
                        bus_raddr <= rd_base + rd_issue;
                        rd_issue  <= rd_issue + 1'b1;
                    end
                    if (rd_pend) begin
                        resp_buf[rd_store] <= bus_rdata;
                        rd_store <= rd_store + 1'b1;
                        if (rd_store == resp_len - 1'b1) begin
                            resp_start <= 1'b1;
                            rx_state   <= WAIT_SOF;
                        end
                    end
                end

                SEND_NACK: if (tx_idle) begin
                    resp_cmd   <= CMD_NACK;
                    resp_addr  <= '0;
                    resp_len   <= '0;
                    resp_start <= 1'b1;
                    rx_state   <= WAIT_SOF;
                end

                default: rx_state <= WAIT_SOF;
            endcase
        end
    end

    // ---- response sender: SOF CMD ADDR_LO ADDR_HI LEN DATA CHECKSUM ----
    typedef enum logic [3:0] {
        S_IDLE, S_SOF, S_CMD, S_ADDR_LO, S_ADDR_HI, S_LEN, S_DATA, S_CKSUM
    } tx_state_t;
    tx_state_t tx_state;
    logic [7:0] s_idx;
    logic [7:0] s_cksum;

    assign tx_idle = (tx_state == S_IDLE) && !resp_start;

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
                S_IDLE: if (resp_start) tx_state <= S_SOF;
                S_SOF: if (!tx_busy) begin
                    tx_byte <= SOF; tx_send <= 1'b1; tx_state <= S_CMD;
                end
                S_CMD: if (!tx_busy && !tx_send) begin
                    tx_byte <= resp_cmd; tx_send <= 1'b1; s_cksum <= resp_cmd; tx_state <= S_ADDR_LO;
                end
                S_ADDR_LO: if (!tx_busy && !tx_send) begin
                    tx_byte <= resp_addr[7:0]; tx_send <= 1'b1;
                    s_cksum <= s_cksum ^ resp_addr[7:0]; tx_state <= S_ADDR_HI;
                end
                S_ADDR_HI: if (!tx_busy && !tx_send) begin
                    tx_byte <= resp_addr[15:8]; tx_send <= 1'b1;
                    s_cksum <= s_cksum ^ resp_addr[15:8]; tx_state <= S_LEN;
                end
                S_LEN: if (!tx_busy && !tx_send) begin
                    tx_byte <= resp_len; tx_send <= 1'b1;
                    s_cksum <= s_cksum ^ resp_len; s_idx <= '0;
                    tx_state <= (resp_len == 8'h00) ? S_CKSUM : S_DATA;
                end
                S_DATA: if (!tx_busy && !tx_send) begin
                    tx_byte <= resp_buf[s_idx]; tx_send <= 1'b1;
                    s_cksum <= s_cksum ^ resp_buf[s_idx];
                    if (s_idx == resp_len - 1'b1) tx_state <= S_CKSUM;
                    s_idx <= s_idx + 1'b1;
                end
                S_CKSUM: if (!tx_busy && !tx_send) begin
                    tx_byte <= s_cksum; tx_send <= 1'b1; tx_state <= S_IDLE;
                end
                default: tx_state <= S_IDLE;
            endcase
        end
    end

endmodule
