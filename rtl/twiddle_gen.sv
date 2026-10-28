`timescale 1ns/1ps
// Online geometric sequence factor_i = seed * step^i mod Q.
// start installs seed and step. factor remains stable until an accepted advance
// finishes. advance is accepted only when valid=1. The caller holds off until
// valid returns (input sampled at edge k, factor updated after k+3). start must only
// occur while !busy; reset discards all outstanding work.
module twiddle_gen #(
    parameter integer W = 32,
    parameter [W-1:0] Q = 2013265921
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [W-1:0] seed,
    input wire [W-1:0] step,
    input wire advance,
    output reg [W-1:0] factor,
    output reg valid,
    output reg busy
);
    reg [W-1:0] step_q;
    wire multiply = advance && valid && !start;
    wire multiply_done;
    wire [W-1:0] next_factor;
    mod_mul #(.W(W), .Q(Q)) multiplier (
        .clk(clk), .rst_n(rst_n), .in_valid(multiply),
        .a(factor), .b(step_q), .out_valid(multiply_done), .result(next_factor)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            factor <= 0;
            step_q <= 0;
            valid <= 0;
            busy <= 0;
        end else if (start) begin
            factor <= seed;
            step_q <= step;
            valid <= 1;
            busy <= 0;
        end else if (multiply) begin
            valid <= 0;
            busy <= 1;
        end else if (busy && multiply_done) begin
            factor <= next_factor;
            valid <= 1;
            busy <= 0;
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)
        if (rst_n && start && busy)
            $fatal(1, "twiddle_gen start asserted while busy");
`endif
endmodule
