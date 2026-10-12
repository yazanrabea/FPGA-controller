`timescale 1ns / 1ps

module single_pin_tester (
    input wire clk,             // 100MHz main clock (10ns period)
    input wire [4:0] sw,        // 5 physical toggle switches
    output wire [31:0] out_pins // 32 output pins on the FMC connector
);

    // 1. Create a counter to count exactly 100 ticks (0 to 99)
    reg [6:0] counter = 0;

    always @(posedge clk) begin
        if (counter == 99) begin
            counter <= 0;       // Reset after 100 ticks (1,000 ns total)
        end else begin
            counter <= counter + 1;
        end
    end

    // 2. Make the wave HIGH for the first 50 ticks, and LOW for the next 50 ticks
    wire wave_1mhz = (counter < 50) ? 1'b1 : 1'b0;

    // 3. Route the 1 MHz wave to the pin chosen by the switches
    assign out_pins = (wave_1mhz == 1'b1) ? (32'b1 << sw) : 32'b0;

endmodule