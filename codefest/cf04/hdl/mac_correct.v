`default_nettype none

module mac (
    input  wire                 clk,
    input  wire                 rst,
    input  wire signed [7:0]    a,
    input  wire signed [7:0]    b,
    output reg  signed [31:0]   out
);

    wire signed [15:0] product;
    assign product = a * b;

    wire signed [31:0] product_ext;
    assign product_ext = {{16{product[15]}}, product};

    always @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + product_ext;
        end
    end

endmodule

`default_nettype wire
