`timescale 1ns/1ps

module edge_actu_rcp_rsqrt_pipe (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire        in_rsqrt,
  input  wire [21:0] in_value_bf22,
  output wire        out_valid,
  output wire [21:0] out_value_bf22
);

// Standalone raw-BF22 compatibility boundary. Integrated ACTU uses the
// classified core directly, so it does not repeat this payload decode.
wire [2:0] value_class, result_class;
wire [21:0] result_candidate;
// Only the standalone raw boundary materializes the legacy positive zero.
assign out_value_bf22=(result_class==3'd1)?22'b0:result_candidate;
assign value_class = (in_value_bf22[20:13] == 0) ?
                    ((|in_value_bf22[12:0]) ? 3'd2 : 3'd1) :
                    (in_value_bf22[20:13] == 8'hff) ?
                    ((|in_value_bf22[12:0]) ? 3'd5 : 3'd4) : 3'd0;
edge_actu_rcp_rsqrt_classified_pipe core (
  .clk(clk), .cpurst_b(cpurst_b), .in_valid(in_valid),
  .in_rsqrt(in_rsqrt), .in_value_bf22(in_value_bf22),
  .in_value_class(value_class), .out_valid(out_valid),
  .out_value_bf22(result_candidate), .out_value_class(result_class)
);
endmodule

`timescale 1ns/1ps

module edge_actu_rcp_rsqrt_classified_pipe #(parameter FINITE_INPUTS=0) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire        in_rsqrt,
  input  wire [21:0] in_value_bf22,
  input  wire [2:0]  in_value_class,
  output wire [2:0]  out_value_class,
  output wire        out_valid,
  output wire [21:0] out_value_bf22
);

reg         valid_s0, valid_s1, valid_s2, valid_s3;
reg         valid_s4, valid_s5, valid_s6;
reg         rsqrt_s0, rsqrt_s1, rsqrt_s2, rsqrt_s3;
reg         rsqrt_s4, rsqrt_s5, rsqrt_s6;
reg         sign_s0, sign_s1, sign_s2, sign_s3;
reg         sign_s4, sign_s5, sign_s6;
reg         invalid_s0, invalid_s1, invalid_s2, invalid_s3;
reg         invalid_s4, invalid_s5, invalid_s6;
reg signed [9:0] exp_s0, exp_s1, exp_s2, exp_s3;
reg signed [9:0] exp_s4, exp_s5, exp_s6;
reg [17:0]  norm_s0;
reg [16:0]  seed_s0, seed_s1, seed_s2, seed_s3, seed_s4;
reg [17:0]  common_mul_s2;
reg [17:0]  rsqrt_t1_s4;
reg [17:0]  rcp_result_s4;
reg [17:0]  rcp_result_s5;
reg [17:0]  result_s6;

wire [4:0]  mant_idx;
wire signed [9:0] unbiased_exp;
wire        exponent_odd;
wire [16:0] seed_q16;
wire [17:0] mant_q16;
wire [17:0] norm_q16;
wire        invalid_input;
wire [17:0] common_mul_q16;
wire [17:0] rcp_corr_q16;
wire [17:0] rsqrt_t1_q16;
wire [17:0] rcp_result_q16;
wire [17:0] rsqrt_half_q16;
wire [17:0] rsqrt_corr_q16;
wire [17:0] rsqrt_result_q16;
wire signed [10:0] scale_exp;
wire signed [10:0] exp_s6_ext;
wire                 result_is_one;
wire [17:0]          normalized_result;
wire signed [10:0]   result_exp;
wire signed [11:0]   biased_exp;
wire [12:0]          result_fraction;

assign mant_idx = in_value_bf22[12:8];
assign unbiased_exp = {2'b0, in_value_bf22[20:13]} - 10'sd127;
assign exponent_odd = unbiased_exp[0];
assign mant_q16 = {1'b0, 1'b1, in_value_bf22[12:0], 3'b0};
assign norm_q16 = in_rsqrt && exponent_odd ? (mant_q16 << 1) : mant_q16;
// Integrated caller resolves input zero/Inf/NaN/domain cases at entry.
// Only arithmetic underflow remains a numerical result observation.
assign invalid_input = !FINITE_INPUTS && ((in_value_class == 3'd1)
                    || (in_value_class == 3'd4)
                    || (in_value_class == 3'd5)
                    || (in_rsqrt && in_value_bf22[21]));

edge_actu_rcp_rsqrt_seed_q16 x_seed (
  .mant_idx(mant_idx),
  .rsqrt_mode(in_rsqrt),
  .exponent_odd(exponent_odd),
  .seed_q16(seed_q16)
);

// S1/S2: register two 14x7 partial products, then add and round once to Q16.
edge_actu_mul14_round9_q16 #(.RESET_DATA(0)) x_mul_common (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(norm_s0[17:4]),
  .rhs_sig_i(seed_s0[16:3]),
  .result_q16_o(common_mul_q16)
);

// The correction-only boundary starts the next partial-product pair directly.
// RCP uses 2-m*y0; RSQRT forms m*y0*y0 with the same S3/S4 pair.
assign rcp_corr_q16 = 18'h20000 - common_mul_s2;
edge_actu_mul14_round9_q16 #(.RESET_DATA(0)) x_mul_rsqrt_t1 (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(common_mul_s2[17:4]),
  .rhs_sig_i(seed_s2[16:3]),
  .result_q16_o(rsqrt_t1_q16)
);
edge_actu_mul14_round10_q16 #(.RESET_DATA(0)) x_mul_rcp_result (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(seed_s2[16:3]),
  .rhs_sig_i(rcp_corr_q16[16:3]),
  .result_q16_o(rcp_result_q16)
);

// S5/S6: RSQRT's fixed 0.5 and correction remain shifts/adds; only its final
// product consumes the third two-stage multiplier.  RCP waits two relay stages
// so both modes retain one mixed stream with no bubbles.
assign rsqrt_half_q16 = rsqrt_t1_s4 >> 1;
assign rsqrt_corr_q16 = 18'h18000 - rsqrt_half_q16;
edge_actu_mul14_round10_q16 #(.RESET_DATA(0)) x_mul_rsqrt_result (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(seed_s4[16:3]),
  .rhs_sig_i(rsqrt_corr_q16[16:3]),
  .result_q16_o(rsqrt_result_q16)
);

assign exp_s6_ext = {exp_s6[9], exp_s6};
assign scale_exp = rsqrt_s6 ? -(exp_s6_ext >>> 1) : -exp_s6_ext;
assign result_is_one = (result_s6 == 18'h10000);
assign normalized_result = result_is_one ? result_s6 : (result_s6 << 1);
assign result_exp = result_is_one ? scale_exp : (scale_exp - 11'sd1);
assign biased_exp = result_exp + 12'sd127;
assign result_fraction = normalized_result[15:3];
// Class describes the semantic result, not the candidate encoding. Invalid
// and underflow values travel as ZERO with don't-care magnitude; downstream
// arithmetic must use the sideband, and only the final output materializes zero.
wire result_zero=invalid_s6 || biased_exp <= 0;
assign out_value_class = result_zero ? 3'd1 : 3'd0;
assign out_valid = valid_s6;
// Candidate sign is unconditional; ZERO has positive semantic sign only at
// the terminal output merge. With the current
// exponent preparation, biased_exp <= 254 (RCP) or <= 191 (RSQRT); the former
// overflow-saturation branch is unreachable for every accepted BF22 input.
wire result_sign=sign_s6;
assign out_value_bf22 = {result_sign,biased_exp[7:0],result_fraction};

// Only validity is cancellation state. Numeric-domain flags are packet data.
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    valid_s0<=0;valid_s1<=0;valid_s2<=0;valid_s3<=0;
    valid_s4<=0;valid_s5<=0;valid_s6<=0;
  end else begin
    valid_s0<=in_valid;valid_s1<=valid_s0;valid_s2<=valid_s1;
    valid_s3<=valid_s2;valid_s4<=valid_s3;valid_s5<=valid_s4;valid_s6<=valid_s5;
  end
end

// Seven aligned captures refill before any valid output becomes observable.
always @(posedge clk) begin
    rsqrt_s0 <= in_rsqrt;
    rsqrt_s1 <= rsqrt_s0;
    rsqrt_s2 <= rsqrt_s1;
    rsqrt_s3 <= rsqrt_s2;
    rsqrt_s4 <= rsqrt_s3;
    rsqrt_s5 <= rsqrt_s4;
    rsqrt_s6 <= rsqrt_s5;
    sign_s0 <= in_rsqrt ? 1'b0 : in_value_bf22[21];
    sign_s1 <= sign_s0;
    sign_s2 <= sign_s1;
    sign_s3 <= sign_s2;
    sign_s4 <= sign_s3;
    sign_s5 <= sign_s4;
    sign_s6 <= sign_s5;
    invalid_s0 <= invalid_input;
    invalid_s1 <= invalid_s0;
    invalid_s2 <= invalid_s1;
    invalid_s3 <= invalid_s2;
    invalid_s4 <= invalid_s3;
    invalid_s5 <= invalid_s4;
    invalid_s6 <= invalid_s5;
    exp_s0 <= unbiased_exp;
    exp_s1 <= exp_s0;
    exp_s2 <= exp_s1;
    exp_s3 <= exp_s2;
    exp_s4 <= exp_s3;
    exp_s5 <= exp_s4;
    exp_s6 <= exp_s5;
    norm_s0 <= norm_q16;
    seed_s0 <= seed_q16;
    seed_s1 <= seed_s0;
    seed_s2 <= seed_s1;
    seed_s3 <= seed_s2;
    seed_s4 <= seed_s3;
    common_mul_s2 <= common_mul_q16;
    rsqrt_t1_s4 <= rsqrt_t1_q16;
    rcp_result_s4 <= rcp_result_q16;
    rcp_result_s5 <= rcp_result_s4;
    result_s6 <= rsqrt_s5 ? rsqrt_result_q16 : rcp_result_s5;
end

endmodule
