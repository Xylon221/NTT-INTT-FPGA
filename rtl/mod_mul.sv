`timescale 1ns/1ps
// Fully pipelined Barrett reduction for canonical 0 <= a,b < Q.
// Three register stages, initiation interval = 1. A request sampled at edge k
// produces out_valid/result just after edge k+2. Reset cancels pending requests.
module mod_mul #(
    parameter integer W = 32,
    parameter [W-1:0] Q = 2013265921
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             in_valid,
    input  wire [W-1:0]     a,
    input  wire [W-1:0]     b,
    output reg              out_valid,
    output reg  [W-1:0]     result
);
    // Division here is an elaboration-time constant, never a runtime divider.
    localparam [2*W:0] RADIX_SQUARED = {1'b1, {(2*W){1'b0}}};
    localparam [2*W:0] MU = RADIX_SQUARED / Q;

    reg [2*W-1:0] product_s1, product_s2;
    reg [W-1:0] quotient_s2;
    reg valid_s1, valid_s2;
    wire [4*W:0] reciprocal_product = product_s1 * MU;
    wire [2*W-1:0] quotient_product = quotient_s2 * Q;
    wire [2*W:0] remainder_wide =
        {1'b0, product_s2} - {1'b0, quotient_product};
    wire [2*W:0] corrected = remainder_wide >= Q
        ? remainder_wide - Q : remainder_wide;

    always @(posedge clk) begin
        if (!rst_n) begin
            product_s1 <= 0;
            product_s2 <= 0;
            quotient_s2 <= 0;
            valid_s1 <= 0;
            valid_s2 <= 0;
            out_valid <= 0;
            result <= 0;
        end else begin
            valid_s1 <= in_valid;
            valid_s2 <= valid_s1;
            out_valid <= valid_s2;
            product_s1 <= a * b;
            product_s2 <= product_s1;
            quotient_s2 <= reciprocal_product[2*W +: W];
            result <= corrected[W-1:0];
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (W < 2 || Q < 2)
            $fatal(1, "mod_mul requires W >= 2 and Q >= 2");
    end
    always @(posedge clk)
        if (rst_n && in_valid && (a >= Q || b >= Q))
            $fatal(1, "mod_mul inputs must be canonical: a=%0d b=%0d Q=%0d", a, b, Q);
`endif
endmodule
