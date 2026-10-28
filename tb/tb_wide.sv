`timescale 1ns/1ps
// 64-bit arithmetic checked against Python arbitrary-precision golden values.
module tb_wide;
    localparam integer COUNT = 512;
    localparam [63:0] Q = 64'hffffffff00000001;
    reg clk = 0;
    always #5 clk=~clk;
    reg rst_n = 0, in_valid = 0;
    reg [63:0] a=0,b=0,twiddle=0;
    wire mm_valid, bf_valid;
    wire [63:0] product,y0,y1;
    mod_mul #(.W(64),.Q(Q)) mm (
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.a(a),.b(b),
        .out_valid(mm_valid),.result(product)
    );
    butterfly #(.W(64),.Q(Q)) bf (
        .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.a(a),.b(b),.twiddle(twiddle),
        .out_valid(bf_valid),.y0(y0),.y1(y1)
    );
    reg [383:0] vectors [0:COUNT-1];
    string vector_dir;
    integer accepted=0, mul_checked=0, bf_checked=0, cycle=0;
    integer mul_due[0:COUNT-1], bf_due[0:COUNT-1];
    always @(posedge clk) begin
        if (!rst_n) begin
            accepted=0; mul_checked=0; bf_checked=0; cycle=0;
        end else begin
            cycle=cycle+1;
            if (in_valid) begin
                if (accepted >= COUNT) $fatal(1,"too many wide requests");
                mul_due[accepted]=cycle+2;
                bf_due[accepted]=cycle+3;
                accepted=accepted+1;
            end
            #1;
            if (mm_valid) begin
                if (mul_checked >= accepted || mul_due[mul_checked] != cycle)
                    $fatal(1,"wide mod_mul valid/order/latency failure");
                if (product !== vectors[mul_checked][191:128])
                    $fatal(1,"wide mod_mul case=%0d got=%h expected=%h",
                        mul_checked,product,vectors[mul_checked][191:128]);
                mul_checked=mul_checked+1;
            end else if (mul_checked < accepted && mul_due[mul_checked] == cycle)
                $fatal(1,"wide mod_mul dropped result");
            if (bf_valid) begin
                if (bf_checked >= accepted || bf_due[bf_checked] != cycle)
                    $fatal(1,"wide butterfly valid/order/latency failure");
                if (y0 !== vectors[bf_checked][127:64] || y1 !== vectors[bf_checked][63:0])
                    $fatal(1,"wide butterfly case=%0d got=(%h,%h) expected=(%h,%h)",
                        bf_checked,y0,y1,vectors[bf_checked][127:64],vectors[bf_checked][63:0]);
                bf_checked=bf_checked+1;
            end else if (bf_checked < accepted && bf_due[bf_checked] == cycle)
                $fatal(1,"wide butterfly dropped result");
        end
    end
    integer i;
    initial begin
        if (!$value$plusargs("VECTORS=%s",vector_dir)) vector_dir="build/wide_vectors";
        $readmemh({vector_dir,"/cases.hex"},vectors);
        // Missing/truncated files must fail rather than compare X against X.
        for (i=0;i<COUNT;i=i+1)
            if ((^vectors[i]) === 1'bx) $fatal(1,"missing/invalid wide vector %0d",i);
        repeat(3) @(negedge clk);
        rst_n=1;
        for (i=0;i<COUNT;i=i+1) begin
            @(negedge clk);
            in_valid=1;
            {a,b,twiddle}=vectors[i][383:192];
            // Long bursts with occasional bubbles exercise pipeline alignment.
            if (i%31==30) begin
                @(negedge clk); in_valid=0;
            end
        end
        @(negedge clk); in_valid=0;
        repeat(8) @(negedge clk);
        if (accepted != COUNT || mul_checked != COUNT || bf_checked != COUNT)
            $fatal(1,"wide scoreboards not complete");
        $display("PASS wide arithmetic: W=64 Q=%0d products=%0d butterflies=%0d",Q,mul_checked,bf_checked);
        $finish;
    end
    initial begin #20000; $fatal(1,"wide arithmetic watchdog timeout"); end
endmodule
