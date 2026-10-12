module sipo_wrapper #(
    parameter WL_num = 16,
    parameter BL_num = 8,
    parameter WIDTH  = BL_num + 8*WL_num
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic             serial_in,
    input  logic             clk_s,
    input  logic             phirst,
    output logic [23:0]      sel,
    output logic             sipo_out
);

    //-----------------------------------------
    // SIPO output
    //-----------------------------------------
    logic [WIDTH-1:0] parallel_out;

    sipo #(
        .WL_num(WL_num),
        .BL_num(BL_num),
        .WIDTH (WIDTH)
    ) u_sipo (
        .clk          (clk),
        .rst_n        (rst_n),
        .serial_in    (serial_in),
        .clk_s        (clk_s),
        .parallel_out (parallel_out),
        .sipo_out     (sipo_out)
    );

    //-----------------------------------------
    // Lower 8 bits always fixed
    //-----------------------------------------
    assign sel[7:0] = parallel_out[7:0];

    //-----------------------------------------
    // Upper 16 bits shift control
    //-----------------------------------------
    logic [$clog2(WIDTH)-1:0] index;

    always_ff @(posedge phirst or negedge rst_n) begin
        if (!rst_n) begin
            index       <= 24;  // first 24 already used
            sel[23:8]   <= parallel_out[23:8];  // initial load
        end
        else begin
            sel[23:8] <= parallel_out[index +: 16];
            index     <= index + 16;
        end
    end

endmodule