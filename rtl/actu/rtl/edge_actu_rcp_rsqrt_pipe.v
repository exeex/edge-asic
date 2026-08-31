`timescale 1ns/1ps

module edge_actu_rcp_rsqrt_pipe (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire        in_rsqrt,
  input  wire [31:0] in_value,
  output wire        out_valid,
  output wire [31:0] out_value
);

reg         valid_s0;
reg         valid_s1;
reg         valid_s2;
reg         valid_s3;
reg         valid_s4;
reg         rsqrt_s0;
reg         rsqrt_s1;
reg         rsqrt_s2;
reg         rsqrt_s3;
reg         rsqrt_s4;
reg         sign_s0;
reg         sign_s1;
reg         sign_s2;
reg         sign_s3;
reg         sign_s4;
reg         invalid_s0;
reg         invalid_s1;
reg         invalid_s2;
reg         invalid_s3;
reg         invalid_s4;
reg signed [9:0] exp_s0;
reg signed [9:0] exp_s1;
reg signed [9:0] exp_s2;
reg signed [9:0] exp_s3;
reg signed [9:0] exp_s4;
reg [17:0]  norm_s0;
reg [16:0]  seed_s0;
reg [16:0]  seed_s1;
reg [16:0]  seed_s2;
reg [16:0]  seed_s3;
reg [17:0]  common_mul_s1;
reg [17:0]  rcp_corr_s2;
reg [17:0]  rsqrt_t1_s2;
reg [17:0]  rcp_result_s3;
reg [17:0]  rsqrt_corr_s3;
reg [17:0]  result_s4;

wire [4:0]  mant_idx;
wire signed [9:0] unbiased_exp;
wire        exponent_odd;
wire [16:0] seed_q16;
wire [17:0] mant_q16;
wire [17:0] norm_q16;
wire        invalid_input;
wire [27:0] common_mul_product;
wire [27:0] common_mul_rounded;
wire [17:0] common_mul_q16;
wire [17:0] rcp_corr_q16;
wire [27:0] rsqrt_t1_product;
wire [27:0] rsqrt_t1_rounded;
wire [17:0] rsqrt_t1_q16;
wire [27:0] rcp_result_product;
wire [27:0] rcp_result_rounded;
wire [17:0] rcp_result_q16;
wire [17:0] rsqrt_half_q16;
wire [17:0] rsqrt_corr_q16;
wire [27:0] rsqrt_result_product;
wire [27:0] rsqrt_result_rounded;
wire [17:0] rsqrt_result_q16;
wire signed [10:0] scale_exp;
wire signed [10:0] exp_s3_ext;
wire                 result_is_one;
wire [17:0]          normalized_result;
wire signed [10:0]   result_exp;
wire signed [11:0]   biased_exp;
wire [22:0]          result_fraction;

assign mant_idx = in_value[22:18];
assign unbiased_exp = {2'b0, in_value[30:23]} - 10'sd127;
assign exponent_odd = unbiased_exp[0];
assign mant_q16 = {1'b0, 1'b1, in_value[22:7]};
assign norm_q16 = in_rsqrt && exponent_odd ? (mant_q16 << 1) : mant_q16;
assign invalid_input = (in_value[30:0] == 31'b0)
                    || (in_value[30:23] == 8'hff)
                    || (in_rsqrt && in_value[31]);

edge_actu_rcp_rsqrt_seed_q16 x_seed (
  .mant_idx(mant_idx),
  .rsqrt_mode(in_rsqrt),
  .exponent_odd(exponent_odd),
  .seed_q16(seed_q16)
);

// Both operations start with the same product m*y0.  Keep the registered
// state/result in Q16, but truncate the multiplier operands to 14 bits.  Norm
// needs two integer bits (Q12); the seed remains Q13.  The product is rounded
// once, back into the Q16 accumulator domain.
assign common_mul_product = norm_s0[17:4] * seed_s0[16:3];
assign common_mul_rounded = common_mul_product + 28'h0000100;
assign common_mul_q16 = common_mul_rounded[26:9];

// RCP S2 is correction-only.  RSQRT uses the same cycle for its second
// product, forming m*y0*y0 with one rounded Q16 result per stage.  The S1
// result can reach 2 for odd-exponent RSQRT, so it keeps two integer bits.
assign rcp_corr_q16 = 18'h20000 - common_mul_s1;
assign rsqrt_t1_product = common_mul_s1[17:4] * seed_s1[16:3];
assign rsqrt_t1_rounded = rsqrt_t1_product + 28'h0000100;
assign rsqrt_t1_q16 = rsqrt_t1_rounded[26:9];

// RCP S3 is its final multiply.  RSQRT S3 is correction-only; multiplying
// by 0.5 is a fixed-point right shift and does not infer a multiplier.
assign rcp_result_product = seed_s2[16:3] * rcp_corr_s2[16:3];
assign rcp_result_rounded = rcp_result_product + 28'h0000200;
assign rcp_result_q16 = rcp_result_rounded[27:10];
assign rsqrt_half_q16 = rsqrt_t1_s2 >> 1;
assign rsqrt_corr_q16 = 18'h18000 - rsqrt_half_q16;
assign rsqrt_result_product = seed_s3[16:3] * rsqrt_corr_s3[16:3];
assign rsqrt_result_rounded = rsqrt_result_product + 28'h0000200;
assign rsqrt_result_q16 = rsqrt_result_rounded[27:10];

assign exp_s3_ext = {exp_s4[9], exp_s4};
assign scale_exp = rsqrt_s4 ? -(exp_s3_ext >>> 1) : -exp_s3_ext;
assign result_is_one = (result_s4 == 18'h10000);
assign normalized_result = result_is_one ? result_s4 : (result_s4 << 1);
assign result_exp = result_is_one ? scale_exp : (scale_exp - 11'sd1);
assign biased_exp = result_exp + 12'sd127;
assign result_fraction = {normalized_result[15:0], 7'b0};
assign out_valid = valid_s4;
assign out_value = invalid_s4 ? 32'b0 :
                   (biased_exp <= 0 ? 32'b0 :
                    (biased_exp >= 255 ? {sign_s4, 8'hfe, 23'h7fffff} :
                     {sign_s4, biased_exp[7:0], result_fraction}));

always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    valid_s0 <= 1'b0;
    valid_s1 <= 1'b0;
    valid_s2 <= 1'b0;
    valid_s3 <= 1'b0;
    valid_s4 <= 1'b0;
    rsqrt_s0 <= 1'b0;
    rsqrt_s1 <= 1'b0;
    rsqrt_s2 <= 1'b0;
    rsqrt_s3 <= 1'b0;
    rsqrt_s4 <= 1'b0;
    sign_s0 <= 1'b0;
    sign_s1 <= 1'b0;
    sign_s2 <= 1'b0;
    sign_s3 <= 1'b0;
    sign_s4 <= 1'b0;
    invalid_s0 <= 1'b0;
    invalid_s1 <= 1'b0;
    invalid_s2 <= 1'b0;
    invalid_s3 <= 1'b0;
    invalid_s4 <= 1'b0;
    exp_s0 <= 10'sd0;
    exp_s1 <= 10'sd0;
    exp_s2 <= 10'sd0;
    exp_s3 <= 10'sd0;
    exp_s4 <= 10'sd0;
    norm_s0 <= 18'b0;
    seed_s0 <= 17'b0;
    seed_s1 <= 17'b0;
    seed_s2 <= 17'b0;
    seed_s3 <= 17'b0;
    common_mul_s1 <= 18'b0;
    rcp_corr_s2 <= 18'b0;
    rsqrt_t1_s2 <= 18'b0;
    rcp_result_s3 <= 18'b0;
    rsqrt_corr_s3 <= 18'b0;
    result_s4 <= 18'b0;
  end else begin
    valid_s0 <= in_valid;
    valid_s1 <= valid_s0;
    valid_s2 <= valid_s1;
    valid_s3 <= valid_s2;
    valid_s4 <= valid_s3;
    rsqrt_s0 <= in_rsqrt;
    rsqrt_s1 <= rsqrt_s0;
    rsqrt_s2 <= rsqrt_s1;
    rsqrt_s3 <= rsqrt_s2;
    rsqrt_s4 <= rsqrt_s3;
    sign_s0 <= in_rsqrt ? 1'b0 : in_value[31];
    sign_s1 <= sign_s0;
    sign_s2 <= sign_s1;
    sign_s3 <= sign_s2;
    sign_s4 <= sign_s3;
    invalid_s0 <= invalid_input;
    invalid_s1 <= invalid_s0;
    invalid_s2 <= invalid_s1;
    invalid_s3 <= invalid_s2;
    invalid_s4 <= invalid_s3;
    exp_s0 <= unbiased_exp;
    exp_s1 <= exp_s0;
    exp_s2 <= exp_s1;
    exp_s3 <= exp_s2;
    exp_s4 <= exp_s3;
    norm_s0 <= norm_q16;
    seed_s0 <= seed_q16;
    seed_s1 <= seed_s0;
    seed_s2 <= seed_s1;
    seed_s3 <= seed_s2;
    common_mul_s1 <= common_mul_q16;
    rcp_corr_s2 <= rcp_corr_q16;
    rsqrt_t1_s2 <= rsqrt_t1_q16;
    rcp_result_s3 <= rcp_result_q16;
    rsqrt_corr_s3 <= rsqrt_corr_q16;
    result_s4 <= rsqrt_s3 ? rsqrt_result_q16 : rcp_result_s3;
  end
end

endmodule
