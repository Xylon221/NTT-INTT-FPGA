`timescale 1ns/1ps
// Cooley-Tukey butterfly: (a + b*w, a - b*w) mod Q.
// Four register stages: input at edge k, output just after edge k+3; II=1.
module butterfly #(
    parameter integer W = 32,
    parameter [W-1:0] Q = 2013265921
) (
    input wire clk,
    input wire rst_n,
    input wire in_valid,
    input wire [W-1:0] a,
    input wire [W-1:0] b,
    input wire [W-1:0] twiddle,
    output reg out_valid,
    output reg [W-1:0] y0,
    output reg [W-1:0] y1
);
    wire mul_valid;
    wire [W-1:0] product;
    reg [W-1:0] a_s1, a_s2, a_s3;
    wire [W:0] sum = {1'b0,a_s3} + {1'b0,product};
    wire [W:0] difference = a_s3 >= product
        ? {1'b0,a_s3} - {1'b0,product}
        : {1'b0,a_s3} + {1'b0,Q} - {1'b0,product};
    mod_mul #(.W(W), .Q(Q)) multiplier (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .a(b), .b(twiddle), .out_valid(mul_valid), .result(product)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            a_s1 <= 0;
            a_s2 <= 0;
            a_s3 <= 0;
            out_valid <= 0;
            y0 <= 0;
            y1 <= 0;
        end else begin
            a_s1 <= a;
            a_s2 <= a_s1;
            a_s3 <= a_s2;
            out_valid <= mul_valid;
            y0 <= sum >= Q ? sum - Q : sum;
            y1 <= difference[W-1:0];
        end
    end
endmodule
