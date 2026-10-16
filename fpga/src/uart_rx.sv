`timescale 1ns / 1ps
//==========================================================================
// uart_rx
//
// Standard 8-N-1 UART receiver (1 start bit, 8 data bits LSB first, 1 stop
// bit, no parity), same CLK_FREQ_HZ/BAUD parameterization as uart_tx.sv.
// `rx` is treated as asynchronous (CLAUDE.md §8: synchronize every
// asynchronous input) and gets its own 2-FF synchronizer here, separate
// from the one `cap_cell.sv` expects upstream of itself -- this one is
// about recovering a clean digital level off an external UART line, not
// about an already-digital chip-output pin.
//
// Classic oversample-to-mid-bit design: on the synchronized line's
// falling edge (start bit), wait half a bit period to land on the start
// bit's middle (and re-check it's still 0 -- rejects a glitch that looked
// like a start edge), then sample every subsequent bit exactly one full
// bit period later, landing on each bit's middle in turn.
//
// `valid` pulses for one cycle with `data_out` holding the received byte.
// `frame_error` pulses alongside it if the stop bit wasn't 1 (a framing
// error -- noise, wrong baud rate, or a disconnected/floating line) --
// `data_out` is still produced in that case, but the caller should treat
// it as suspect.
//==========================================================================
module uart_rx #(
    parameter int CLK_FREQ_HZ = 100_000_000,
    parameter int BAUD        = 115_200
) (
    input  logic       clk,
    input  logic       rst_n,      // async reset, active low

    input  logic       rx,

    output logic [7:0] data_out,
    output logic        valid,
    output logic        frame_error
);

    localparam int BAUD_DIV = CLK_FREQ_HZ / BAUD;
    localparam int HALF_DIV = BAUD_DIV / 2;
    localparam int CNT_W    = $clog2(BAUD_DIV + 1);

    // 2-FF synchronizer + previous-cycle value, for edge detection
    logic rx_s0, rx_s1, rx_s1_d;

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;

    logic [CNT_W-1:0] bit_cnt;
    logic [2:0]       bit_idx;
    logic [7:0]       shift_reg;

    wire start_edge = rx_s1_d && !rx_s1;  // falling edge: idle(1) -> start(0)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s0 <= 1'b1; rx_s1 <= 1'b1; rx_s1_d <= 1'b1;
            state       <= IDLE;
            bit_cnt     <= '0;
            bit_idx     <= '0;
            shift_reg   <= '0;
            data_out    <= '0;
            valid       <= 1'b0;
            frame_error <= 1'b0;
        end else begin
            rx_s0   <= rx;
            rx_s1   <= rx_s0;
            rx_s1_d <= rx_s1;
            valid       <= 1'b0;
            frame_error <= 1'b0;

            case (state)
                IDLE: begin
                    if (start_edge) begin
                        state   <= START;
                        bit_cnt <= '0;
                    end
                end
                START: begin
                    if (bit_cnt == HALF_DIV - 1) begin
                        if (!rx_s1) begin  // still low at the start bit's middle: real start
                            state   <= DATA;
                            bit_cnt <= '0;
                            bit_idx <= '0;
                        end else begin     // was just a glitch
                            state <= IDLE;
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                DATA: begin
                    if (bit_cnt == BAUD_DIV - 1) begin
                        bit_cnt <= '0;
                        shift_reg[bit_idx] <= rx_s1;
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
                    if (bit_cnt == BAUD_DIV - 1) begin
                        data_out    <= shift_reg;
                        valid       <= 1'b1;
                        frame_error <= !rx_s1;
                        state       <= IDLE;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
