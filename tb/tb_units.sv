`timescale 1ns/1ps
// Independent integer-% scoreboards, streaming traffic, stalls and reset flush.
module tb_units;
    localparam [31:0] Q = 2013265921;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg mul_in = 0, bf_in = 0;
    reg [31:0] ma = 0, mb = 0, ba = 0, bb = 0, bw = 0;
    wire mul_out, bf_out;
    wire [31:0] mr, by0, by1;
    reg tf_start = 0, tf_advance = 0;
    reg [31:0] tf_seed = 0, tf_step = 0;
    wire [31:0] tf_factor;
    wire tf_valid, tf_busy;
    mod_mul #(.Q(Q)) mm(clk, rst_n, mul_in, ma, mb, mul_out, mr);
    butterfly #(.Q(Q)) bf(clk, rst_n, bf_in, ba, bb, bw, bf_out, by0, by1);
    twiddle_gen #(.Q(Q)) tf(clk, rst_n, tf_start, tf_seed, tf_step,
                            tf_advance, tf_factor, tf_valid, tf_busy);

    // A second modulus catches width errors hidden by the 31-bit default Q.
    localparam [31:0] Q2 = 32'hfffffffb;
    wire mul_out2;
    wire [31:0] mr2;
    reg [31:0] ma2=0, mb2=0;
    mod_mul #(.Q(Q2)) mm2(clk, rst_n, mul_in, ma2, mb2, mul_out2, mr2);

    function automatic [31:0] direct_mul(input [31:0] a,b,q);
        reg [63:0] full_product;
        begin full_product = {32'b0,a} * {32'b0,b}; direct_mul = full_product % q; end
    endfunction
    reg [31:0] rng = 32'hc0ffee01;
    function automatic [31:0] random_word(input bit unused);
        begin rng = rng * 32'd1664525 + 32'd1013904223; random_word = rng; end
    endfunction

    reg [31:0] mul_expected[0:8191], mul_expected2[0:8191];
    reg [31:0] bf_expected0[0:8191], bf_expected1[0:8191];
    integer mul_due[0:8191], bf_due[0:8191];
    integer cycle = 0, mw = 0, mrd = 0, bwptr = 0, brd = 0;
    integer total_mul = 0, total_bf = 0, total_tf = 0;
    reg [31:0] prod;
    reg [32:0] sum;
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle = 0; mw = 0; mrd = 0; bwptr = 0; brd = 0;
            #1;
            if (mul_out || mul_out2 || bf_out || tf_valid || tf_busy)
                $fatal(1,"reset failed to clear valid/busy");
        end else begin
            cycle = cycle + 1;
            if (mul_in) begin
                mul_expected[mw] = direct_mul(ma,mb,Q);
                mul_expected2[mw] = direct_mul(ma2,mb2,Q2);
                mul_due[mw] = cycle + 2;
                mw = mw + 1;
            end
            if (bf_in) begin
                prod = direct_mul(bb,bw,Q);
                sum = {1'b0,ba} + {1'b0,prod};
                bf_expected0[bwptr] = sum % Q;
                bf_expected1[bwptr] = ba >= prod ? ba-prod : {1'b0,ba}+Q-prod;
                bf_due[bwptr] = cycle + 3;
                bwptr = bwptr + 1;
            end
            #1;
            if (mul_out !== mul_out2) $fatal(1,"moduli disagree on valid latency");
            if (mul_out) begin
                if (mrd >= mw || mul_due[mrd] != cycle)
                    $fatal(1,"mod_mul latency/order mismatch cycle=%0d", cycle);
                if (mr !== mul_expected[mrd] || mr2 !== mul_expected2[mrd])
                    $fatal(1,"mod_mul case=%0d got=%0d/%0d expected=%0d/%0d",
                        mrd,mr,mr2,mul_expected[mrd],mul_expected2[mrd]);
                mrd=mrd+1; total_mul=total_mul+2;
            end else if (mrd < mw && mul_due[mrd] == cycle)
                $fatal(1,"mod_mul dropped result");
            if (bf_out) begin
                if (brd >= bwptr || bf_due[brd] != cycle)
                    $fatal(1,"butterfly latency/order mismatch");
                if (by0 !== bf_expected0[brd] || by1 !== bf_expected1[brd])
                    $fatal(1,"butterfly case=%0d got=(%0d,%0d) expected=(%0d,%0d)",
                        brd,by0,by1,bf_expected0[brd],bf_expected1[brd]);
                brd=brd+1; total_bf=total_bf+1;
            end else if (brd < bwptr && bf_due[brd] == cycle)
                $fatal(1,"butterfly dropped result");
        end
    end

    task automatic check_tfg(input [31:0] seed, step_value);
        reg [31:0] expected;
        integer idx, stall, wait_count;
        begin
            @(negedge clk);
            tf_seed=seed; tf_step=step_value; tf_start=1;
            @(negedge clk);
            tf_start=0; expected=seed;
            if (!tf_valid || tf_busy || tf_factor !== expected)
                $fatal(1,"TFG seed mismatch");
            for (idx=0; idx<32; idx=idx+1) begin
                stall = random_word(0) % 4;
                repeat(stall) begin
                    @(negedge clk);
                    if (!tf_valid || tf_busy || tf_factor !== expected)
                        $fatal(1,"TFG factor changed without advance");
                end
                tf_advance=1;
                @(negedge clk);
                tf_advance=0;
                if (tf_valid || !tf_busy) $fatal(1,"TFG did not enter busy");
                expected=direct_mul(expected,step_value,Q);
                wait_count=0;
                while (!tf_valid) begin
                    @(negedge clk);
                    wait_count=wait_count+1;
                    if (wait_count>6) $fatal(1,"TFG timeout");
                end
                if (tf_busy || tf_factor !== expected)
                    $fatal(1,"TFG factor=%0d expected=%0d index=%0d",tf_factor,expected,idx+1);
                total_tf=total_tf+1;
            end
        end
    endtask

    integer i;
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        // Abort genuine in-flight traffic, then verify no stale output survives.
        @(negedge clk);
        mul_in=1; bf_in=1; ma=Q-1; mb=Q-1; ma2=Q2-1; mb2=Q2-1;
        ba=Q-1; bb=Q-1; bw=Q-1; tf_start=1; tf_seed=1; tf_step=31;
        @(negedge clk);
        tf_start=0; tf_advance=1;
        @(negedge clk);
        rst_n=0; mul_in=0; bf_in=0; tf_advance=0;
        repeat(2) @(negedge clk);
        rst_n=1;
        repeat(8) @(negedge clk);
        // Alternating corners and random values, with bubbles and long bursts.
        for (i=0;i<4096;i=i+1) begin
            @(negedge clk);
            mul_in = (i % 11 != 5);
            bf_in = (i % 7 != 3);
            case(i%16)
                0: begin ma=0; mb=Q-1; ma2=0; mb2=Q2-1; end
                1: begin ma=Q-1; mb=Q-1; ma2=Q2-1; mb2=Q2-1; end
                2: begin ma=Q-2; mb=Q-2; ma2=Q2-2; mb2=Q2-2; end
                3: begin ma=1; mb=Q-1; ma2=1; mb2=Q2-1; end
                default: begin ma=random_word(0)%Q; mb=random_word(0)%Q;
                    ma2=random_word(0)%Q2; mb2=random_word(0)%Q2; end
            endcase
            ba=random_word(0)%Q; bb=random_word(0)%Q; bw=random_word(0)%Q;
        end
        @(negedge clk); mul_in=0; bf_in=0;
        repeat(8) @(negedge clk);
        if (mrd != mw || brd != bwptr) $fatal(1,"scoreboards not empty");
        check_tfg(1,31);
        check_tfg(Q-1,Q-1);
        check_tfg(0,31);
        check_tfg(1,0);
        check_tfg(Q-1,1);
        for (i=0;i<19;i=i+1)
            check_tfg(random_word(0)%Q,random_word(0)%Q);
        $display("PASS units: modular_products=%0d butterflies=%0d twiddle_advances=%0d",total_mul,total_bf,total_tf);
        $finish;
    end
    initial begin #2000000; $fatal(1,"unit test watchdog timeout"); end
endmodule
