`timescale 1ns/1ps
// Sequential radix-2 DIT transform. Host writes/reads natural coefficient order.
// Negacyclic mode evaluates at psi*omega^k for Z_q[x]/(x^N+1).
module ntt_core #(
    parameter integer LOG_N = 13,
    parameter integer W = 32,
    parameter [W-1:0] Q = 2013265921,
    parameter [W-1:0] PRIMITIVE_ROOT = 31,
    parameter integer USE_TFG = 1,
    parameter ROM_FWD_FILE = "build/vectors/rom_forward.hex",
    parameter ROM_INV_FILE = "build/vectors/rom_inverse.hex"
)(
    input wire clk, rst_n,
    input wire wr_en,
    input wire [LOG_N-1:0] wr_addr,
    input wire [W-1:0] wr_data,
    input wire start, inverse, negacyclic,
    output reg busy, done,
    input wire [LOG_N-1:0] rd_addr,
    output wire [W-1:0] rd_data,
    output reg [63:0] cycle_count
);
    localparam integer N = 1 << LOG_N;
    function automatic [W-1:0] mod_pow;
        input [W-1:0] base;
        input [63:0] exponent;
        reg [W-1:0] acc, cur;
        reg [2*W-1:0] product;
        integer k;
        begin
            acc = 1; cur = base;
            for (k = 0; k < 64; k = k + 1) begin
                if (exponent[k]) begin product = acc * cur; acc = product % Q; end
                product = cur * cur; cur = product % Q;
            end
            mod_pow = acc;
        end
    endfunction
    function automatic [LOG_N-1:0] reverse_bits;
        input [LOG_N-1:0] value;
        integer k;
        begin
            for (k = 0; k < LOG_N; k = k + 1)
                reverse_bits[k] = value[LOG_N-1-k];
        end
    endfunction
    // All mod_pow calls below have constant arguments and elaborate to constants.
    localparam [W-1:0] PSI = mod_pow(PRIMITIVE_ROOT, (Q-1)/(2*N));
    localparam [W-1:0] PSI_INV = mod_pow(PSI, Q-2);
    localparam [W-1:0] N_INV = mod_pow(N, Q-2);
    wire [W-1:0] stage_fwd [0:LOG_N-1];
    wire [W-1:0] stage_inv [0:LOG_N-1];
    genvar s;
    generate for (s = 0; s < LOG_N; s = s + 1) begin : seeds
        localparam [W-1:0] FWD = mod_pow(PRIMITIVE_ROOT, (Q-1)/(1 << (s+1)));
        assign stage_fwd[s] = FWD;
        assign stage_inv[s] = mod_pow(FWD, Q-2);
    end endgenerate

    reg [W-1:0] mem [0:N-1];
    assign rd_data = mem[rd_addr];
    localparam IDLE=0, TWIST_INIT=1, TWIST_ISSUE=2, TWIST_WAIT=3,
               STAGE_INIT=4, BF_ISSUE=5, BF_WAIT=6, FINISH=7;
    reg [3:0] state;
    reg inv_latched, neg_latched;
    integer stage_idx, j, group_base, twist_idx, issued_idx;
    wire [31:0] half_size = 1 << stage_idx;
    wire [31:0] block_size = half_size << 1;
    wire [31:0] bf_idx = group_base + j;
    wire [31:0] rom_idx = j << (LOG_N-1-stage_idx);
    wire [LOG_N-1:0] twist_addr = inv_latched ? twist_idx[LOG_N-1:0]
                                              : reverse_bits(twist_idx[LOG_N-1:0]);

    wire tf_start = state == TWIST_INIT || (USE_TFG && state == STAGE_INIT);
    wire [W-1:0] tf_seed = state == TWIST_INIT && inv_latched ? N_INV : 1;
    wire [W-1:0] tf_step = state == TWIST_INIT
        ? (neg_latched ? (inv_latched ? PSI_INV : PSI) : {{(W-1){1'b0}},1'b1})
        : (inv_latched ? stage_inv[stage_idx] : stage_fwd[stage_idx]);
    wire [W-1:0] tf_factor;
    wire tf_valid, tf_busy;
    wire bf_issue = state == BF_ISSUE && (!USE_TFG || tf_valid);
    wire twist_issue = state == TWIST_ISSUE && tf_valid;
    wire tf_advance = (twist_issue && twist_idx < N-1) ||
        (USE_TFG && bf_issue && group_base == N-block_size && j < half_size-1);
    twiddle_gen #(.W(W), .Q(Q)) tfg (
        .clk(clk), .rst_n(rst_n), .start(tf_start), .seed(tf_seed), .step(tf_step),
        .advance(tf_advance), .factor(tf_factor), .valid(tf_valid), .busy(tf_busy)
    );
    wire [W-1:0] bf_twiddle;
    generate if (USE_TFG) begin : online
        assign bf_twiddle = tf_factor;
    end else begin : lookup
        reg [W-1:0] rom_fwd [0:N/2-1];
        reg [W-1:0] rom_inv [0:N/2-1];
        initial begin
            $readmemh(ROM_FWD_FILE, rom_fwd);
            $readmemh(ROM_INV_FILE, rom_inv);
        end
        assign bf_twiddle = inv_latched ? rom_inv[rom_idx] : rom_fwd[rom_idx];
    end endgenerate
    wire bf_valid;
    wire [W-1:0] bf_y0, bf_y1;
    butterfly #(.W(W), .Q(Q)) bf (
        .clk(clk), .rst_n(rst_n), .in_valid(bf_issue),
        .a(mem[bf_idx]), .b(mem[bf_idx+half_size]), .twiddle(bf_twiddle),
        .out_valid(bf_valid), .y0(bf_y0), .y1(bf_y1)
    );
    wire scale_valid;
    wire [W-1:0] scale_result;
    mod_mul #(.W(W), .Q(Q)) scaler (
        .clk(clk), .rst_n(rst_n), .in_valid(twist_issue),
        .a(mem[twist_addr]), .b(tf_factor), .out_valid(scale_valid), .result(scale_result)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; busy <= 0; done <= 0; cycle_count <= 0;
            inv_latched <= 0; neg_latched <= 0;
            stage_idx <= 0; j <= 0; group_base <= 0; twist_idx <= 0; issued_idx <= 0;
        end else begin
            done <= 0;
            if (busy) cycle_count <= cycle_count + 1;
            if (!busy && wr_en) mem[reverse_bits(wr_addr)] <= wr_data;
            case (state)
                IDLE: if (start && !wr_en) begin
                    busy <= 1; cycle_count <= 0;
                    inv_latched <= inverse; neg_latched <= negacyclic;
                    stage_idx <= 0; j <= 0; group_base <= 0; twist_idx <= 0;
                    state <= (!inverse && negacyclic) ? TWIST_INIT : STAGE_INIT;
                end
                TWIST_INIT: state <= TWIST_ISSUE;
                TWIST_ISSUE: if (tf_valid) begin
                    issued_idx <= twist_addr;
                    state <= TWIST_WAIT;
                end
                TWIST_WAIT: if (scale_valid) begin
                    mem[issued_idx] <= scale_result;
                    if (twist_idx == N-1) begin
                        if (inv_latched) state <= FINISH;
                        else state <= STAGE_INIT;
                    end else begin
                        twist_idx <= twist_idx + 1;
                        state <= TWIST_ISSUE;
                    end
                end
                STAGE_INIT: begin j <= 0; group_base <= 0; state <= BF_ISSUE; end
                BF_ISSUE: if (!USE_TFG || tf_valid) begin
                    issued_idx <= bf_idx;
                    state <= BF_WAIT;
                end
                BF_WAIT: if (bf_valid) begin
                    mem[issued_idx] <= bf_y0;
                    mem[issued_idx+half_size] <= bf_y1;
                    if (group_base < N-block_size) begin
                        group_base <= group_base + block_size;
                        state <= BF_ISSUE;
                    end else if (j < half_size-1) begin
                        group_base <= 0; j <= j + 1;
                        state <= BF_ISSUE;
                    end else if (stage_idx < LOG_N-1) begin
                        stage_idx <= stage_idx + 1;
                        state <= STAGE_INIT;
                    end else if (inv_latched) begin
                        twist_idx <= 0; state <= TWIST_INIT;
                    end else state <= FINISH;
                end
                FINISH: begin busy <= 0; done <= 1; state <= IDLE; end
                default: begin busy <= 0; state <= IDLE; end
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (LOG_N < 1 || LOG_N > 20 || W < 3 || W > 64)
            $fatal(1, "Unsupported LOG_N or W");
        if (USE_TFG != 0 && USE_TFG != 1)
            $fatal(1, "USE_TFG must be 0 or 1");
        if ((Q-1) % (2*N) != 0 || mod_pow(PSI,N) != Q-1)
            $fatal(1, "Q/root must support a primitive 2N-th root; validate with Python first");
    end
    always @(posedge clk) if (rst_n && !busy && wr_en && wr_data >= Q)
        $fatal(1, "Host coefficient is not canonical");
`endif
endmodule
