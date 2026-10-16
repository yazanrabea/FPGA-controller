`timescale 1ns / 1ps
//==========================================================================
// uart_tx
//
// Standard 8-N-1 UART transmitter (1 start bit, 8 data bits LSB first, 1
// stop bit, no parity), parameterized by system clock and baud rate so the
// same module works in simulation (fast clock, fast baud, quick testbenches)
// and on hardware (100 MHz, 115200 by default -- a common USB-UART bridge
// rate, not confirmed against any specific adapter since none is in this
// repo; see docs/USER_MANUAL.md Phase 5 section for the open PMOD-voltage
// item this still depends on).
//
// `tx` idles high. Pulse `send` for one cycle with `data_in` valid; `busy`
// stays high until the stop bit finishes. A `send` while `busy` is ignored
// (the caller must wait for `busy` to drop).
//==========================================================================
module uart_tx #(
    parameter int CLK_FREQ_HZ = 100_000_000,
    parameter int BAUD        = 115_200
) (
    input  logic       clk,
    input  logic       rst_n,      // async reset, active low

    input  logic [7:0] data_in,
    input  logic       send,       // 1-cycle strobe; ignored while busy
    output logic       busy,

    output logic       tx
);

    localparam int BAUD_DIV = CLK_FREQ_HZ / BAUD;  // clk cycles per bit period
    localparam int CNT_W    = $clog2(BAUD_DIV + 1);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;

    logic [CNT_W-1:0] bit_cnt;     // ticks within the current bit period
    logic [2:0]       bit_idx;     // which data bit (0..7) is being sent
    logic [7:0]       shift_reg;

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            bit_cnt   <= '0;
            bit_idx   <= '0;
            shift_reg <= '0;
            tx        <= 1'b1;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (send) begin
                        shift_reg <= data_in;
                        state     <= START;
                        bit_cnt   <= '0;
                    end
                end
                START: begin
                    tx <= 1'b0;
                    if (bit_cnt == BAUD_DIV - 1) begin
                        bit_cnt <= '0;
                        bit_idx <= '0;
                        state   <= DATA;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                DATA: begin
                    tx <= shift_reg[0];
                    if (bit_cnt == BAUD_DIV - 1) begin
                        bit_cnt   <= '0;
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_idx == 3'd7) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                STOP: begin
                    tx <= 1'b1;
                    if (bit_cnt == BAUD_DIV - 1) begin
                        bit_cnt <= '0;
                        state   <= IDLE;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
