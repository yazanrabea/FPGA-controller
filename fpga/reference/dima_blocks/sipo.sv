module sipo #(
    parameter WL_num = 16,
    parameter BL_num = 8,
    parameter WIDTH  = BL_num + 8*WL_num
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              serial_in,
    input  logic              clk_s,   // clk for the ctrl reg - cs
    output logic [WIDTH-1:0]  parallel_out,
    output logic              sipo_out
);

    // Internal signals
    logic [WIDTH-1:0] parallel_out_before_s;
    logic [WIDTH-1:0] shift_reg;

    // Shift register (serial shift domain)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= '0;
        end else begin
            // Shift left and insert new bit at LSB
            shift_reg <= {shift_reg[WIDTH-2:0], serial_in};
        end
    end

    // Serial output (LSB)
    assign sipo_out = shift_reg[0];

    // Capture value before synchronization
    assign parallel_out_before_s = shift_reg;

    // Register into second clock domain
    always_ff @(posedge clk_s or negedge rst_n) begin
        if (!rst_n) begin
            parallel_out <= '0;   // Correct reset syntax
        end else begin
            parallel_out <= parallel_out_before_s;
        end
    end

endmodule
