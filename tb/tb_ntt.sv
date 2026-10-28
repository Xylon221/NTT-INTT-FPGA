`timescale 1ns/1ps
module tb_ntt;
    parameter integer LOG_N = 13;
    parameter integer W = 32;
    parameter [W-1:0] Q = 2013265921;
    parameter [W-1:0] PRIMITIVE_ROOT = 31;
    parameter integer USE_TFG = 1;
    parameter VECTOR_DIR = "build/vectors";
    localparam integer N = 1 << LOG_N;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, wr_en=0, start=0, inverse=0, negacyclic=0;
    reg [LOG_N-1:0] wr_addr=0, rd_addr=0;
    reg [W-1:0] wr_data=0;
    wire busy, done;
    wire [W-1:0] rd_data;
    wire [63:0] cycle_count;
    ntt_core #(.LOG_N(LOG_N), .W(W), .Q(Q), .PRIMITIVE_ROOT(PRIMITIVE_ROOT),
        .USE_TFG(USE_TFG), .ROM_FWD_FILE({VECTOR_DIR,"/rom_forward.hex"}),
        .ROM_INV_FILE({VECTOR_DIR,"/rom_inverse.hex"})) dut (.*);

    reg [W-1:0] a [0:N-1], b [0:N-1];
    reg [W-1:0] expected_forward [0:N-1], expected_inverse [0:N-1];
    reg [W-1:0] expected_forward_neg [0:N-1], expected_b_neg [0:N-1];
    reg [W-1:0] expected_inverse_neg [0:N-1], expected_freq [0:N-1];
    reg [W-1:0] expected_product [0:N-1];
    reg [W-1:0] actual_a_ntt [0:N-1], actual_b_ntt [0:N-1], actual_freq [0:N-1];
    reg point_valid=0;
    reg [W-1:0] point_a=0, point_b=0;
    wire point_out_valid;
    wire [W-1:0] point_result;
    mod_mul #(.W(W),.Q(Q)) pointwise (.clk(clk),.rst_n(rst_n),
        .in_valid(point_valid),.a(point_a),.b(point_b),
        .out_valid(point_out_valid),.result(point_result));
    integer total_checked=0;
    integer watchdog=0;
    always @(posedge clk) begin
        watchdog <= watchdog+1;
        if (watchdog > 100*N*(LOG_N+10)) $fatal(1,"Global timeout: state=%0d",dut.state);
    end

    // bank 0=a, 1=b, 2=actual pointwise RTL output.
    task automatic transform;
        input integer bank;
        input integer inv;
        input integer neg;
        input integer oracle;
        input [255:0] label;
        integer i, waited;
        reg [W-1:0] expected;
        begin
            if (busy) $fatal(1,"transform started while busy");
            for (i=0;i<N;i=i+1) begin
                @(negedge clk);
                wr_en=1; wr_addr=i;
                case (bank)
                    0: wr_data=a[i];
                    1: wr_data=b[i];
                    default: wr_data=actual_freq[i];
                endcase
            end
            @(negedge clk); wr_en=0; inverse=inv; negacyclic=neg; start=1;
            @(negedge clk); start=0;
            // Inputs may change after acceptance; mode must have been latched.
            inverse=!inv; negacyclic=!neg;
            waited=0;
            while (!done) begin
                @(negedge clk);
                waited=waited+1;
                // Host traffic while busy must be ignored by the compute core.
                if (waited==4) begin wr_en=1; wr_addr=0; wr_data=0; start=1; end
                if (waited==5) begin wr_en=0; start=0; end
                if (waited>50*N*(LOG_N+10))
                    $fatal(1,"Transform timeout: %0s state=%0d",label,dut.state);
            end
            if (busy) $fatal(1,"busy must deassert on done");
            for (i=0;i<N;i=i+1) begin
                rd_addr=i; #1;
                case (oracle)
                    0: expected=expected_forward[i];
                    1: expected=expected_inverse[i];
                    2: expected=expected_forward_neg[i];
                    3: expected=expected_b_neg[i];
                    4: expected=expected_inverse_neg[i];
                    default: expected=expected_product[i];
                endcase
                if ((^rd_data) === 1'bx || rd_data !== expected)
                    $fatal(1,"%0s mode=%0d n=%0d coefficient=%0d expected=%h actual=%h",
                        label,USE_TFG,N,i,expected,rd_data);
                if (oracle==2) actual_a_ntt[i]=rd_data;
                if (oracle==3) actual_b_ntt[i]=rd_data;
                total_checked=total_checked+1;
            end
            $display("METRIC mode=%0d n=%0d op=%0s cycles=%0d checked=%0d",
                USE_TFG,N,label,cycle_count,N);
            @(negedge clk);
        end
    endtask
    task automatic reset_in_flight;
        integer i;
        begin
            for (i=0;i<N;i=i+1) begin
                @(negedge clk); wr_en=1; wr_addr=i; wr_data=a[i];
            end
            @(negedge clk); wr_en=0; start=1; inverse=0; negacyclic=1;
            @(negedge clk); start=0;
            repeat(12) @(negedge clk);
            if (!busy) $fatal(1,"reset test expected an active transform");
            rst_n=0;
            repeat(3) @(negedge clk);
            if (busy || done || cycle_count!=0) $fatal(1,"reset failed to cancel transform");
            rst_n=1;
            repeat(3) @(negedge clk);
            if (done) $fatal(1,"stale completion after reset");
        end
    endtask
    task automatic multiply_pointwise;
        integer sent, received, ticks;
        begin
            received=0; ticks=0;
            fork
                begin
                    for (sent=0;sent<N;sent=sent+1) begin
                        @(negedge clk); point_valid=1;
                        point_a=actual_a_ntt[sent]; point_b=actual_b_ntt[sent];
                    end
                    @(negedge clk); point_valid=0;
                end
                begin
                    while (received<N) begin
                        @(posedge clk); #1; ticks=ticks+1;
                        if (point_out_valid) begin
                            if ((^point_result) === 1'bx || point_result !== expected_freq[received])
                                $fatal(1,"pointwise coefficient=%0d expected=%h actual=%h",
                                    received,expected_freq[received],point_result);
                            actual_freq[received]=point_result;
                            total_checked=total_checked+1;
                            received=received+1;
                        end
                        if (ticks>N+20) $fatal(1,"pointwise timeout");
                    end
                end
            join
            $display("METRIC mode=%0d n=%0d op=pointwise cycles=%0d checked=%0d",
                USE_TFG,N,ticks,N);
        end
    endtask
    integer vector_index;
    initial begin
        $readmemh({VECTOR_DIR,"/a.hex"},a);
        $readmemh({VECTOR_DIR,"/b.hex"},b);
        $readmemh({VECTOR_DIR,"/forward.hex"},expected_forward);
        $readmemh({VECTOR_DIR,"/inverse.hex"},expected_inverse);
        $readmemh({VECTOR_DIR,"/forward_neg.hex"},expected_forward_neg);
        $readmemh({VECTOR_DIR,"/b_ntt_neg.hex"},expected_b_neg);
        $readmemh({VECTOR_DIR,"/inverse_neg.hex"},expected_inverse_neg);
        $readmemh({VECTOR_DIR,"/product_freq.hex"},expected_freq);
        $readmemh({VECTOR_DIR,"/product.hex"},expected_product);
        // Never accept matching X values as evidence of arithmetic correctness.
        // $readmemh alone may merely warn and continue on missing/short files.
        for (vector_index=0;vector_index<N;vector_index=vector_index+1) begin
            if ((^a[vector_index]) === 1'bx || (^b[vector_index]) === 1'bx ||
                (^expected_forward[vector_index]) === 1'bx ||
                (^expected_inverse[vector_index]) === 1'bx ||
                (^expected_forward_neg[vector_index]) === 1'bx ||
                (^expected_b_neg[vector_index]) === 1'bx ||
                (^expected_inverse_neg[vector_index]) === 1'bx ||
                (^expected_freq[vector_index]) === 1'bx ||
                (^expected_product[vector_index]) === 1'bx)
                $fatal(1,"Missing, short or unknown vector coefficient=%0d",vector_index);
        end
        if ($test$plusargs("VCD")) begin $dumpfile("build/ntt.vcd"); $dumpvars(0,tb_ntt); end
        repeat(4) @(negedge clk);
        rst_n=1;
        reset_in_flight();
        transform(0,0,0,0,"forward_cyclic");
        transform(0,1,0,1,"inverse_cyclic");
        transform(0,1,1,4,"inverse_negacyclic");
        transform(0,0,1,2,"forward_negacyclic_a");
        transform(1,0,1,3,"forward_negacyclic_b");
        multiply_pointwise();
        transform(2,1,1,5,"product_inverse");
        $display("PASS integration mode=%0d n=%0d coefficients=%0d",USE_TFG,N,total_checked);
        $finish;
    end
endmodule
