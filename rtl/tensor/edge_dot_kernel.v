// First half of the central exponent-domain pipeline.  Product-exponent
// addition is registered before the balanced max tree so dot16 does not put
// an exponent add and four comparator levels in the same 1 GHz cycle.
module edge_dot_product_exp #(
  parameter LANES = 8
)(
  input  [LANES*8-1:0] activation_exp_i,
  input  [LANES*8-1:0] weight_exp_i,
  input  [LANES-1:0]   activation_nonzero_i,
  input  [LANES-1:0]   weight_nonzero_i,
  input                  weight_bf16_mode_i,
  output [LANES*10-1:0] product_exp_o,
  output [LANES-1:0] product_valid_o
);
genvar exp_lane;
generate
  for (exp_lane = 0; exp_lane < LANES; exp_lane = exp_lane + 1) begin
    : EXP_LANE
    wire [7:0] activation_exp = activation_exp_i[exp_lane*8 +: 8];
    wire [7:0] weight_exp = weight_exp_i[exp_lane*8 +: 8];
    wire signed [9:0] product_exp = weight_bf16_mode_i
      ? ($signed({2'b0,(activation_exp==0)?8'd1:activation_exp})
         + $signed({2'b0,(weight_exp==0)?8'd1:weight_exp}) - 10'sd134)
      : $signed({2'b0,activation_exp});
    assign product_exp_o[exp_lane*10 +: 10] = product_exp;
    assign product_valid_o[exp_lane]
      = activation_nonzero_i[exp_lane] && weight_nonzero_i[exp_lane];
  end
endgenerate
endmodule

// Second half of the central exponent-domain pipeline: a balanced max tree
// over already-registered per-lane product exponents.
module edge_dot_exp_max #(
  parameter LANES = 8
)(
  input  [LANES*10-1:0] product_exp_i,
  input  [LANES-1:0]    product_valid_i,
  output signed [9:0]   global_max_exp_o
);
wire [10:0] candidate [0:LANES-1];
wire [10:0] max_l1 [0:7];
wire [10:0] max_l2 [0:3];
wire [10:0] max_l3 [0:1];
wire [10:0] max_root;

function [10:0] max_candidate;
  input [10:0] a;
  input [10:0] b;
  begin
    if (!a[10]) max_candidate = b;
    else if (!b[10]) max_candidate = a;
    else if ($signed(a[9:0]) >= $signed(b[9:0])) max_candidate = a;
    else max_candidate = b;
  end
endfunction

genvar max_lane;
generate
  for (max_lane = 0; max_lane < LANES; max_lane = max_lane + 1) begin
    : MAX_CANDIDATE
    assign candidate[max_lane]
      = {product_valid_i[max_lane],
         product_exp_i[max_lane*10 +: 10]};
  end
  if (LANES == 16) begin : MAX16
    for (max_lane = 0; max_lane < 8; max_lane = max_lane + 1)
      assign max_l1[max_lane]
        = max_candidate(candidate[max_lane*2],candidate[max_lane*2+1]);
    for (max_lane = 0; max_lane < 4; max_lane = max_lane + 1)
      assign max_l2[max_lane]
        = max_candidate(max_l1[max_lane*2],max_l1[max_lane*2+1]);
    assign max_l3[0] = max_candidate(max_l2[0],max_l2[1]);
    assign max_l3[1] = max_candidate(max_l2[2],max_l2[3]);
    assign max_root = max_candidate(max_l3[0],max_l3[1]);
  end else begin : MAX8
    for (max_lane = 0; max_lane < 4; max_lane = max_lane + 1)
      assign max_l1[max_lane]
        = max_candidate(candidate[max_lane*2],candidate[max_lane*2+1]);
    assign max_l2[0] = max_candidate(max_l1[0],max_l1[1]);
    assign max_l2[1] = max_candidate(max_l1[2],max_l1[3]);
    assign max_root = max_candidate(max_l2[0],max_l2[1]);
  end
endgenerate
assign global_max_exp_o = max_root[10] ? $signed(max_root[9:0]) : 10'sd0;
endmodule

// Central exponent-only pipeline. Keep the common -134 bias out of the max
// and shift critical paths: shift = max(raw_exp) - raw_exp. BF16 uses the sum
// of effective exponents; I8 uses activation_exp+134 in the same unsigned domain.
module edge_dot_exp_parallel #(parameter LANES = 16)(
  input clk, rst_b,
  input [LANES*8-1:0] activation_exp_i, weight_exp_i,
  input [LANES-1:0] activation_nonzero_i, weight_nonzero_i,
  input weight_bf16_mode_i,
  output signed [9:0] max_exp_o,
  output [LANES*11-1:0] shift_o
);
// Six comparisons run concurrently. Ties select the lowest input index.
// The one-hot decode is a small Boolean LUT, not a wide exponent ROM.
function [9:0] max4_parallel;
  input [9:0] a,b,c,d;
  reg ab,ac,ad,bc,bd,cd;
  reg wa,wb,wc,wd;
  begin
    ab=(a>=b); ac=(a>=c); ad=(a>=d);
    bc=(b>=c); bd=(b>=d); cd=(c>=d);
    wa=ab && ac && ad;
    wb=!ab && bc && bd;
    wc=!ac && !bc && cd;
    wd=!ad && !bd && !cd;
    max4_parallel=({10{wa}} & a) | ({10{wb}} & b)
                | ({10{wc}} & c) | ({10{wd}} & d);
  end
endfunction
localparam GROUPS = LANES/4;
reg [8:0] s0_raw_exp [0:LANES-1];
reg s0_eligible [0:LANES-1];
reg [8:0] s1_raw_exp [0:LANES-1];
reg [9:0] s1_group_max [0:GROUPS-1];
wire [9:0] tree [1:2*GROUPS-1];
wire [8:0] maximum = tree[1][9] ? tree[1][8:0] : 9'd134;
genvar k;
generate
  for(k=0;k<LANES;k=k+1) begin : EXP_LANE
    wire [7:0] ae=activation_exp_i[k*8+:8];
    wire [7:0] we=weight_exp_i[k*8+:8];
    wire [8:0] raw_exp = weight_bf16_mode_i
      ? {1'b0,(ae==0 ? 8'd1 : ae)} + {1'b0,(we==0 ? 8'd1 : we)}
      : {1'b0,ae} + 9'd134;
    always @(posedge clk) if(rst_b) begin
      s0_raw_exp[k] <= raw_exp;
      s0_eligible[k] <= activation_nonzero_i[k] && weight_nonzero_i[k];
      s1_raw_exp[k] <= s0_raw_exp[k];
    end
    assign shift_o[k*11+:11] = $signed({2'b0,maximum}) - $signed({2'b0,s1_raw_exp[k]});
  end
  for(k=0;k<GROUPS;k=k+1) begin : GROUP_MAX
    wire [9:0] a={s0_eligible[4*k],s0_raw_exp[4*k]};
    wire [9:0] b={s0_eligible[4*k+1],s0_raw_exp[4*k+1]};
    wire [9:0] c={s0_eligible[4*k+2],s0_raw_exp[4*k+2]};
    wire [9:0] d={s0_eligible[4*k+3],s0_raw_exp[4*k+3]};
    always @(posedge clk) if(rst_b) s1_group_max[k] <= max4_parallel(a,b,c,d);
    assign tree[GROUPS+k]=s1_group_max[k];
  end
  if(GROUPS==4) begin : FINAL_MAX4
    assign tree[1]=max4_parallel(s1_group_max[0],s1_group_max[1],
      s1_group_max[2],s1_group_max[3]);
  end else begin : FINAL_BINARY
    for(k=1;k<GROUPS;k=k+1) begin : MAX
      assign tree[k]=(tree[2*k]>=tree[2*k+1])?tree[2*k]:tree[2*k+1];
    end
  end
endgenerate
assign max_exp_o = $signed({1'b0,maximum}) - 10'sd134;
endmodule

// Local multiplier lane.  Exponent arithmetic is intentionally absent; the
// lane consumes only significands/signs and later receives a shift distance.
module edge_dot_mul_lane #(
  parameter FPGA_DSP_MUL = 0
)(
  input  [15:0] activation_i,
  input  [7:0]  int8_weight_i,
  input  [15:0] bf16_weight_i,
  input         weight_bf16_mode_i,
  output [15:0] product_o,
  output        sign_o
);
wire [7:0] activation_sig = (activation_i[14:7] == 0)
  ? {1'b0, activation_i[6:0]} : {1'b1, activation_i[6:0]};
wire [7:0] int8_magnitude = int8_weight_i[7]
  ? (~int8_weight_i + 8'b1) : int8_weight_i;
wire [7:0] weight_sig = (bf16_weight_i[14:7] == 0)
  ? {1'b0, bf16_weight_i[6:0]} : {1'b1, bf16_weight_i[6:0]};
wire [7:0] selected_weight_sig = weight_bf16_mode_i
                               ? weight_sig : int8_magnitude;
edge_bf16_sig_mul #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_sig_mul (
  .activation_sig_i(activation_sig),
  .weight_sig_i(selected_weight_sig),
  .product_o(product_o)
);
assign sign_o = activation_i[15]
              ^ (weight_bf16_mode_i ? bf16_weight_i[15]
                                     : int8_weight_i[7]);
endmodule

// First half of the local alignment shifter.  The central exp-max cluster has
// already converted both exponents into shift_amount_i.
module edge_dot_align_lane_coarse #(
  parameter ALIGN_GUARD_BITS = 0
)(
  input  [15:0] product_i,
  input  signed [10:0] shift_amount_i,
  output reg [17:0] coarse_o,
  output reg [2:0]  fine_o,
  output reg        coarse_guard_o,
  output reg        coarse_sticky_o,
  output reg        force_zero_o
);
reg [17:0] expanded_product;
always @* begin
  expanded_product = {2'b0, product_i} << ALIGN_GUARD_BITS;
  fine_o = shift_amount_i[2:0];
  force_zero_o = (shift_amount_i >= (17 + ALIGN_GUARD_BITS));
  case (shift_amount_i[4:3])
    2'd0: begin
      coarse_o = expanded_product;
      coarse_guard_o = 1'b0;
      coarse_sticky_o = 1'b0;
    end
    2'd1: begin
      coarse_o = expanded_product >> 8;
      coarse_guard_o = expanded_product[7];
      coarse_sticky_o = |expanded_product[6:0];
    end
    2'd2: begin
      coarse_o = expanded_product >> 16;
      coarse_guard_o = expanded_product[15];
      coarse_sticky_o = |expanded_product[14:0];
    end
    default: begin
      coarse_o = 18'b0;
      coarse_guard_o = 1'b0;
      coarse_sticky_o = |expanded_product;
    end
  endcase
end
endmodule

// Second half of the distributed alignment corridor.  This leaf consumes the
// registered coarse result while it moves toward the signed adder tree.
module edge_dot_align_lane_fine(
  input  [17:0] coarse_i,
  input  [2:0]  fine_i,
  input         coarse_guard_i,
  input         coarse_sticky_i,
  input         force_zero_i,
  input         sign_i,
  output signed [20:0] aligned_o
);
reg [17:0] quotient;
reg guard_bit;
reg sticky_bit;
reg [17:0] rounded;
reg signed [20:0] signed_aligned;
always @* begin
  quotient = coarse_i;
  guard_bit = coarse_guard_i;
  sticky_bit = coarse_sticky_i;
  case (fine_i)
    3'd0: quotient = coarse_i;
    3'd1: begin quotient=coarse_i>>1; guard_bit=coarse_i[0];
      sticky_bit=coarse_guard_i|coarse_sticky_i; end
    3'd2: begin quotient=coarse_i>>2; guard_bit=coarse_i[1];
      sticky_bit=coarse_i[0]|coarse_guard_i|coarse_sticky_i; end
    3'd3: begin quotient=coarse_i>>3; guard_bit=coarse_i[2];
      sticky_bit=(|coarse_i[1:0])|coarse_guard_i|coarse_sticky_i; end
    3'd4: begin quotient=coarse_i>>4; guard_bit=coarse_i[3];
      sticky_bit=(|coarse_i[2:0])|coarse_guard_i|coarse_sticky_i; end
    3'd5: begin quotient=coarse_i>>5; guard_bit=coarse_i[4];
      sticky_bit=(|coarse_i[3:0])|coarse_guard_i|coarse_sticky_i; end
    3'd6: begin quotient=coarse_i>>6; guard_bit=coarse_i[5];
      sticky_bit=(|coarse_i[4:0])|coarse_guard_i|coarse_sticky_i; end
    default: begin quotient=coarse_i>>7; guard_bit=coarse_i[6];
      sticky_bit=(|coarse_i[5:0])|coarse_guard_i|coarse_sticky_i; end
  endcase
  rounded = force_zero_i ? 18'b0
    : quotient + (guard_bit && (sticky_bit || quotient[0]));
  signed_aligned = $signed({3'b0, rounded});
  if (sign_i) signed_aligned = -signed_aligned;
end
assign aligned_o = signed_aligned;
endmodule

// One reusable dual-mode BF16 x {INT8, BF16} dot8 row.
//
// Pipeline:
//   s0: sanitize BF16 lanes; parallel exponent island captures unbiased sums
//   s1: PARALLEL_MAX_SHIFT captures four local exponent maxima and mantissa
//       operands; otherwise product-exponent adds and magnitude products
//   s2: global exponent max; PARALLEL_MAX_SHIFT finishes 4-to-1, captures shifts and
//       parallel mantissa multiplies, otherwise it relays products
//   s3: coarse product alignment by 0/8/16/24 bits
//   s4: fine product alignment by 0..7 bits, RNE, and sign
//   s5: signed adder tree; SPLIT_REDUCTION adds s5a (16-to-4) before s5 (4-to-1)
//   s6: normalize the row sum; either round directly to BF16 or accumulate
//       successive row sums in the private BF22 RSUM accumulator
//   r6: emit one BF16 result when the RSUM sequence marks its last row

module edge_dot_kernel #(
  parameter PARTIAL_ONLY = 0,
  parameter FPGA_DSP_ADD = 0,
  parameter FPGA_DSP_MUL = 0,
  parameter LANES = 8,
  parameter SUM_WIDTH = (LANES == 16) ? 25 : 24,
  parameter ALIGN_GUARD_BITS = 0,
  parameter INPUTS_SANITIZED = 0,
  parameter EXTERNAL_WEIGHT_EXP = 0,
  parameter EXTERNAL_PRODUCTS = 0,
  // External leaf captures operands at s0; its combinational product enters s1.
  parameter EXTERNAL_PRODUCTS_REGISTERED = 0,
  // E4 partial-only dot16: insert a full-precision 16-to-4 capture.
  parameter SPLIT_REDUCTION = 0,
  // Retimed product and precomputed shift meet at s2.
  parameter PARALLEL_MAX_SHIFT = 0
)(
  clk,
  rst_b,
  in_valid,
  bf16_vec_i,
  int8_vec_i,
  weight_bf16_mode_i,
  bf16_weight_vec_i,
  weight_exp_vec_i,
  external_product_vec_i,
  external_product_sign_i,
  rsum_enable_i,
  rsum_first_i,
  rsum_last_i,
  out_valid,
  bf22_o,
  bf16_o,
  partial_valid_o,
  partial_sum_o,
  partial_exp_o
);

input          clk;
input          rst_b;
input          in_valid;
input  [LANES*16-1:0] bf16_vec_i;
input  [LANES*8-1:0]  int8_vec_i;
input          weight_bf16_mode_i;
input  [LANES*16-1:0] bf16_weight_vec_i;
input  [LANES*8-1:0]  weight_exp_vec_i;
input  [LANES*16-1:0] external_product_vec_i;
input  [LANES-1:0]    external_product_sign_i;
input          rsum_enable_i;
input          rsum_first_i;
input          rsum_last_i;
output         out_valid;
output [31:0]  bf22_o;
output [15:0]  bf16_o;
output         partial_valid_o;
output signed [SUM_WIDTH-1:0] partial_sum_o;
output signed [9:0]  partial_exp_o;

reg         s0_valid;
reg         s1_valid;
reg         s2_valid;
reg         s3_valid;
reg         s4_valid;
reg         s5_valid;
reg         s6_valid;
reg [15:0]  s0_bf16 [0:LANES-1];
reg [7:0]   s0_int8 [0:LANES-1];
reg [15:0]  s0_weight_bf16 [0:LANES-1];
// External-product rows consume only exponent metadata and nonzero predicates.
// Capture each predicate with its input, avoiding a tail of significand flops.
reg s0_activation_nonzero [0:LANES-1];
reg s0_weight_nonzero [0:LANES-1];
wire [15:0] ingress_activation [0:LANES-1];
wire [15:0] ingress_weight [0:LANES-1];
reg [7:0]   s0_weight_exp_external [0:LANES-1];
reg [15:0]  s0_external_product [0:LANES-1];
reg         s0_external_product_sign [0:LANES-1];
reg         s0_weight_bf16_mode;
reg [15:0]  s1_prod [0:LANES-1];
reg         s1_sign [0:LANES-1];
reg signed [9:0] s1_exp [0:LANES-1];
reg         s1_exp_valid [0:LANES-1];
reg [15:0]  s2_prod [0:LANES-1];
reg         s2_sign [0:LANES-1];
reg signed [9:0] s2_exp [0:LANES-1];
reg signed [9:0] s2_max_exp;
reg signed [10:0] s2_shift [0:LANES-1];
wire [LANES*11-1:0] parallel_shift;
wire [15:0] parallel_product [0:LANES-1];
wire parallel_sign [0:LANES-1];
reg [17:0]  s3_coarse [0:LANES-1];
reg [2:0]   s3_fine [0:LANES-1];
reg         s3_coarse_guard [0:LANES-1];
reg         s3_coarse_sticky [0:LANES-1];
reg         s3_force_zero [0:LANES-1];
reg         s3_sign [0:LANES-1];
reg signed [9:0] s3_max_exp;
reg signed [20:0] s4_lane [0:LANES-1];
reg signed [9:0] s4_max_exp;
reg signed [SUM_WIDTH-1:0] s5_sum;
reg signed [9:0] s5_max_exp;
reg [15:0]  s6_bf16;
reg [31:0]  s6_bf22_bits;
reg         s0_rsum_enable;
reg         s1_rsum_enable;
reg         s2_rsum_enable;
reg         s3_rsum_enable;
reg         s4_rsum_enable;
reg         s5_rsum_enable;
reg         s6_rsum_enable;
reg         s0_rsum_first;
reg         s1_rsum_first;
reg         s2_rsum_first;
reg         s3_rsum_first;
reg         s4_rsum_first;
reg         s5_rsum_first;
reg         s6_rsum_first;
reg         s0_rsum_last;
reg         s1_rsum_last;
reg         s2_rsum_last;
reg         s3_rsum_last;
reg         s4_rsum_last;
reg         s5_rsum_last;
reg         s6_rsum_last;
reg [31:0]  rsum_accum_q;
reg         rsum_output_valid_q;
reg [31:0]  rsum_output_bf22_q;
reg [15:0]  rsum_output_bf16_q;

integer i;
wire signed [9:0] max_exp_comb;
wire [LANES*10-1:0] product_exp_comb;
wire [LANES-1:0] product_exp_valid_comb;
wire [LANES*10-1:0] s1_product_exp_vec;
wire [LANES-1:0] s1_product_valid_vec;
wire [LANES*8-1:0] ingress_activation_exp, ingress_weight_exp;
wire [LANES-1:0] ingress_activation_nonzero, ingress_weight_nonzero;
wire [LANES*8-1:0] activation_exp_comb;
wire [LANES*8-1:0] weight_exp_comb;
wire [LANES-1:0] activation_nonzero_comb;
wire [LANES-1:0] weight_nonzero_comb;
wire [15:0] product_comb [0:LANES-1];
wire sign_comb [0:LANES-1];
wire signed [10:0] shift_amount_comb [0:LANES-1];
wire [17:0] coarse_comb [0:LANES-1];
wire [2:0] fine_comb [0:LANES-1];
wire coarse_guard_comb [0:LANES-1];
wire coarse_sticky_comb [0:LANES-1];
wire force_zero_comb [0:LANES-1];
wire signed [20:0] aligned_comb [0:LANES-1];

wire [31:0] rsum_base_bits;
wire [31:0] rsum_next_bits;
wire [31:0] rsum_next_bf16_bits;
wire signed [SUM_WIDTH-1:0] s5_sum_next;
wire reduction_valid;
wire signed [9:0] reduction_exp;
wire reduction_rsum_enable, reduction_rsum_first, reduction_rsum_last;
wire signed [SUM_WIDTH-1:0] s4_lane_ext [0:LANES-1];

genvar lane_idx;
generate
  for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin : gen_lane_ext
    assign s4_lane_ext[lane_idx] =
      {{(SUM_WIDTH-21){s4_lane[lane_idx][20]}}, s4_lane[lane_idx]};

    assign s1_product_exp_vec[lane_idx*10 +: 10] = s1_exp[lane_idx];
    assign s1_product_valid_vec[lane_idx] = s1_exp_valid[lane_idx];

    assign activation_exp_comb[lane_idx*8 +: 8]
      = s0_bf16[lane_idx][14:7];
    assign weight_exp_comb[lane_idx*8 +: 8]
      = EXTERNAL_WEIGHT_EXP ? s0_weight_exp_external[lane_idx]
                            : s0_weight_bf16[lane_idx][14:7];
    assign ingress_activation[lane_idx] = INPUTS_SANITIZED
      ? bf16_vec_i[lane_idx*16 +: 16]
      : sanitize_bf16(bf16_vec_i[lane_idx*16 +: 16]);
    assign ingress_weight[lane_idx] = INPUTS_SANITIZED
      ? bf16_weight_vec_i[lane_idx*16 +: 16]
      : sanitize_bf16(bf16_weight_vec_i[lane_idx*16 +: 16]);
    assign ingress_activation_exp[lane_idx*8+:8] = ingress_activation[lane_idx][14:7];
    assign ingress_weight_exp[lane_idx*8+:8] = EXTERNAL_WEIGHT_EXP
      ? weight_exp_vec_i[lane_idx*8+:8] : ingress_weight[lane_idx][14:7];
    assign ingress_activation_nonzero[lane_idx] = |ingress_activation[lane_idx][14:0];
    assign ingress_weight_nonzero[lane_idx] = weight_bf16_mode_i
      ? (|ingress_weight[lane_idx][14:0]) : (|int8_vec_i[lane_idx*8+:8]);
    assign activation_nonzero_comb[lane_idx]
      = EXTERNAL_PRODUCTS ? s0_activation_nonzero[lane_idx]
                          : (s0_bf16[lane_idx][14:0] != 15'b0);
    assign weight_nonzero_comb[lane_idx]
      = EXTERNAL_PRODUCTS ? s0_weight_nonzero[lane_idx]
        : (s0_weight_bf16_mode
           ? (s0_weight_bf16[lane_idx][14:0] != 15'b0)
           : (s0_int8[lane_idx] != 8'b0));

    if (EXTERNAL_PRODUCTS) begin : gen_external_product
      assign product_comb[lane_idx] = EXTERNAL_PRODUCTS_REGISTERED
        ? external_product_vec_i[lane_idx*16 +: 16]
        : s0_external_product[lane_idx];
      assign sign_comb[lane_idx] = EXTERNAL_PRODUCTS_REGISTERED
        ? external_product_sign_i[lane_idx]
        : s0_external_product_sign[lane_idx];
    end else begin : gen_internal_product
      edge_dot_mul_lane #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_mul_lane (
        .activation_i(s0_bf16[lane_idx]),
        .int8_weight_i(s0_int8[lane_idx]),
        .bf16_weight_i(s0_weight_bf16[lane_idx]),
        .weight_bf16_mode_i(s0_weight_bf16_mode),
        .product_o(product_comb[lane_idx]),
        .sign_o(sign_comb[lane_idx])
      );
    end

    if (PARALLEL_MAX_SHIFT) begin : gen_parallel_product
      if (EXTERNAL_PRODUCTS) begin : gen_local
        // External leaf relays selected operands at s1, multiplies into s2.
        assign parallel_product[lane_idx] = external_product_vec_i[lane_idx*16+:16];
        assign parallel_sign[lane_idx] = external_product_sign_i[lane_idx];
      end else begin : gen_direct
        reg [7:0] activation_sig_q, weight_sig_q;
        reg sign_q;
        wire [7:0] i8_mag = s0_int8[lane_idx][7]
          ? -s0_int8[lane_idx] : s0_int8[lane_idx];
        always @(posedge clk) if (rst_b) begin
          activation_sig_q <= {(s0_bf16[lane_idx][14:7]!=0),s0_bf16[lane_idx][6:0]};
          weight_sig_q <= s0_weight_bf16_mode
            ? {(s0_weight_bf16[lane_idx][14:7]!=0),s0_weight_bf16[lane_idx][6:0]} : i8_mag;
          sign_q <= s0_bf16[lane_idx][15] ^ (s0_weight_bf16_mode
            ? s0_weight_bf16[lane_idx][15] : s0_int8[lane_idx][7]);
        end
        edge_bf16_sig_mul #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_mul (
          .activation_sig_i(activation_sig_q),.weight_sig_i(weight_sig_q),
          .product_o(parallel_product[lane_idx]));
        assign parallel_sign[lane_idx] = sign_q;
      end
    end else begin : gen_no_parallel_product
      assign parallel_product[lane_idx] = 16'b0;
      assign parallel_sign[lane_idx] = 1'b0;
    end
    assign shift_amount_comb[lane_idx] = PARALLEL_MAX_SHIFT
      ? s2_shift[lane_idx]
      : ($signed(s2_max_exp) - $signed(s2_exp[lane_idx]));
    edge_dot_align_lane_coarse #(
      .ALIGN_GUARD_BITS(ALIGN_GUARD_BITS)
    ) x_align_lane (
      .product_i(s2_prod[lane_idx]),
      .shift_amount_i(shift_amount_comb[lane_idx]),
      .coarse_o(coarse_comb[lane_idx]),
      .fine_o(fine_comb[lane_idx]),
      .coarse_guard_o(coarse_guard_comb[lane_idx]),
      .coarse_sticky_o(coarse_sticky_comb[lane_idx]),
      .force_zero_o(force_zero_comb[lane_idx])
    );

    edge_dot_align_lane_fine x_align_lane_fine (
      .coarse_i(s3_coarse[lane_idx]),
      .fine_i(s3_fine[lane_idx]),
      .coarse_guard_i(s3_coarse_guard[lane_idx]),
      .coarse_sticky_i(s3_coarse_sticky[lane_idx]),
      .force_zero_i(s3_force_zero[lane_idx]),
      .sign_i(s3_sign[lane_idx]),
      .aligned_o(aligned_comb[lane_idx])
    );
  end
endgenerate

edge_dot_product_exp #(.LANES(LANES)) x_product_exp (
  .activation_exp_i(activation_exp_comb),
  .weight_exp_i(weight_exp_comb),
  .activation_nonzero_i(activation_nonzero_comb),
  .weight_nonzero_i(weight_nonzero_comb),
  .weight_bf16_mode_i(s0_weight_bf16_mode),
  .product_exp_o(product_exp_comb),
  .product_valid_o(product_exp_valid_comb)
);

generate
  if (PARALLEL_MAX_SHIFT) begin : gen_parallel_exp
    edge_dot_exp_parallel #(.LANES(LANES)) x_max_shift (
      .clk(clk),.rst_b(rst_b),
      .activation_exp_i(ingress_activation_exp),.weight_exp_i(ingress_weight_exp),
      .activation_nonzero_i(ingress_activation_nonzero),
      .weight_nonzero_i(ingress_weight_nonzero),.weight_bf16_mode_i(weight_bf16_mode_i),
      .max_exp_o(max_exp_comb),.shift_o(parallel_shift));
  end else begin : gen_serial_exp
    edge_dot_exp_max #(.LANES(LANES)) x_exp_max (
      .product_exp_i(s1_product_exp_vec),.product_valid_i(s1_product_valid_vec),
      .global_max_exp_o(max_exp_comb));
    assign parallel_shift = 0;
  end
endgenerate

generate
  if (SPLIT_REDUCTION && LANES == 16) begin : gen_split_add16
    reg signed [22:0] s5a_group [0:3];
    reg signed [9:0] s5a_exp;
    reg s5a_valid;
    reg s5a_rsum_enable, s5a_rsum_first, s5a_rsum_last;
    for (genvar group_idx = 0; group_idx < 4; group_idx = group_idx + 1) begin : gen_group
      wire signed [21:0] pair01 =
        {s4_lane[group_idx*4][20], s4_lane[group_idx*4]} +
        {s4_lane[group_idx*4+1][20], s4_lane[group_idx*4+1]};
      wire signed [21:0] pair23 =
        {s4_lane[group_idx*4+2][20], s4_lane[group_idx*4+2]} +
        {s4_lane[group_idx*4+3][20], s4_lane[group_idx*4+3]};
      always @(posedge clk) begin
        if (rst_b) s5a_group[group_idx] <=
          {pair01[21], pair01} + {pair23[21], pair23};
      end
    end
    always @(posedge clk or negedge rst_b) begin
      if (!rst_b) begin
        s5a_valid <= 1'b0;
        s5a_rsum_enable <= 1'b0;
        s5a_rsum_first <= 1'b0;
        s5a_rsum_last <= 1'b0;
      end else begin
        s5a_valid <= s4_valid;
        s5a_rsum_enable <= s4_rsum_enable;
        s5a_rsum_first <= s4_rsum_first;
        s5a_rsum_last <= s4_rsum_last;
      end
    end
    always @(posedge clk) if (rst_b) s5a_exp <= s4_max_exp;
    wire signed [23:0] half01 =
      {s5a_group[0][22], s5a_group[0]} + {s5a_group[1][22], s5a_group[1]};
    wire signed [23:0] half23 =
      {s5a_group[2][22], s5a_group[2]} + {s5a_group[3][22], s5a_group[3]};
    assign s5_sum_next = $signed({half01[23], half01}) + $signed({half23[23], half23});
    assign reduction_valid = s5a_valid;
    assign reduction_exp = s5a_exp;
    assign reduction_rsum_enable = s5a_rsum_enable;
    assign reduction_rsum_first = s5a_rsum_first;
    assign reduction_rsum_last = s5a_rsum_last;
  end else begin : gen_unsplit_add
    assign reduction_valid = s4_valid;
    assign reduction_exp = s4_max_exp;
    assign reduction_rsum_enable = s4_rsum_enable;
    assign reduction_rsum_first = s4_rsum_first;
    assign reduction_rsum_last = s4_rsum_last;
  if (FPGA_DSP_ADD) begin : gen_fpga_dsp_add
    (* use_dsp = "simd" *) wire signed [23:0] sum01 =
      s4_lane_ext[0] + s4_lane_ext[1];
    (* use_dsp = "simd" *) wire signed [23:0] sum23 =
      s4_lane_ext[2] + s4_lane_ext[3];
    (* use_dsp = "simd" *) wire signed [23:0] sum45 =
      s4_lane_ext[4] + s4_lane_ext[5];
    (* use_dsp = "simd" *) wire signed [23:0] sum67 =
      s4_lane_ext[6] + s4_lane_ext[7];
    (* use_dsp = "simd" *) wire signed [23:0] sum0123 = sum01 + sum23;
    (* use_dsp = "simd" *) wire signed [23:0] sum4567 = sum45 + sum67;
    (* use_dsp = "simd" *) wire signed [23:0] sum_all = sum0123 + sum4567;
    assign s5_sum_next = sum_all;
  end else if (LANES == 8) begin : gen_logic_add8
    assign s5_sum_next = s4_lane_ext[0] + s4_lane_ext[1]
                       + s4_lane_ext[2] + s4_lane_ext[3]
                       + s4_lane_ext[4] + s4_lane_ext[5]
                       + s4_lane_ext[6] + s4_lane_ext[7];
  end else begin : gen_logic_add16
    assign s5_sum_next = s4_lane_ext[0] + s4_lane_ext[1]
                       + s4_lane_ext[2] + s4_lane_ext[3]
                       + s4_lane_ext[4] + s4_lane_ext[5]
                       + s4_lane_ext[6] + s4_lane_ext[7]
                       + s4_lane_ext[8] + s4_lane_ext[9]
                       + s4_lane_ext[10] + s4_lane_ext[11]
                       + s4_lane_ext[12] + s4_lane_ext[13]
                       + s4_lane_ext[14] + s4_lane_ext[15];
  end
  end
endgenerate

assign out_valid = PARTIAL_ONLY ? 1'b0
  : (rsum_output_valid_q || (s6_valid && !s6_rsum_enable));
assign bf22_o = PARTIAL_ONLY ? 32'b0
  : (rsum_output_valid_q ? rsum_output_bf22_q : s6_bf22_bits);
assign bf16_o = PARTIAL_ONLY ? 16'b0
  : (rsum_output_valid_q ? rsum_output_bf16_q : s6_bf16);
assign partial_valid_o = s5_valid;
assign partial_sum_o = s5_sum;
assign partial_exp_o = s5_max_exp - ALIGN_GUARD_BITS;
assign rsum_base_bits = s6_rsum_first ? 32'b0 : rsum_accum_q;
assign rsum_next_bits = bf22_round_bits(
    fp32_add_bits(rsum_base_bits, s6_bf22_bits));
assign rsum_next_bf16_bits = bf16_round_bits(rsum_next_bits);

function [31:0] bf16_round_bits;
  input [31:0] bits;
  reg [15:0] rounded;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      rounded = 16'h7fc0;
    end else begin
      rounded = bits[31:16]
              + {15'b0, (bits[15] && (|bits[14:0] || bits[16]))};
      if ((rounded == 16'h0000) && bits[31])
        rounded = 16'h8000;
    end
    bf16_round_bits = {rounded, 16'h0000};
  end
endfunction

function [31:0] bf22_round_bits;
  input [31:0] bits;
  reg [31:0] bias;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      bf22_round_bits = 32'h7fc0_0000;
    end else begin
      bias = 32'h0000_01ff + {31'b0, bits[10]};
      bf22_round_bits = (bits + bias) & 32'hffff_fc00;
    end
  end
endfunction

function [26:0] rshift_sticky27;
  input [26:0] value;
  input integer shift;
  reg sticky;
  begin
    if (shift <= 0) begin
      rshift_sticky27 = value;
    end else if (shift >= 27) begin
      rshift_sticky27 = {|value, 26'b0};
    end else begin
      sticky = |(value & ((27'b1 << shift) - 27'b1));
      rshift_sticky27 = (value >> shift) | {26'b0, sticky};
    end
  end
endfunction

function [31:0] fp32_pack_from_grs;
  input        sign;
  input signed [11:0] exp_unbiased;
  input [26:0] sig_grs;
  reg [23:0] main;
  reg guard_bit;
  reg round_bit;
  reg sticky_bit;
  reg increment;
  reg [24:0] rounded;
  reg signed [11:0] packed_exp_unbiased;
  reg signed [12:0] biased_exp;
  begin
    if (sig_grs == 27'b0 || exp_unbiased < -12'sd126) begin
      fp32_pack_from_grs = {sign, 31'b0};
    end else begin
      main = sig_grs[26:3];
      guard_bit = sig_grs[2];
      round_bit = sig_grs[1];
      sticky_bit = sig_grs[0];
      increment = guard_bit && (round_bit || sticky_bit || main[0]);
      rounded = {1'b0, main} + {24'b0, increment};
      packed_exp_unbiased = exp_unbiased + {11'b0, rounded[24]};
      biased_exp = packed_exp_unbiased + 13'sd127;
      if (biased_exp >= 13'sd255)
        fp32_pack_from_grs = {sign, 8'hfe, 23'h7fffff};
      else if (biased_exp <= 13'sd0)
        fp32_pack_from_grs = {sign, 31'b0};
      else
        fp32_pack_from_grs = {sign, biased_exp[7:0],
                              rounded[24] ? rounded[23:1]
                                          : rounded[22:0]};
    end
  end
endfunction

function [31:0] fp32_add_bits;
  input [31:0] a_bits;
  input [31:0] b_bits;
  reg        sign_a;
  reg        sign_b;
  reg [7:0]  exp_a_bits;
  reg [7:0]  exp_b_bits;
  reg [23:0] sig_a;
  reg [23:0] sig_b;
  reg signed [11:0] exp_a;
  reg signed [11:0] exp_b;
  reg        large_sign;
  reg        small_sign;
  reg signed [11:0] large_exp;
  reg [26:0] large_sig;
  reg [26:0] small_sig;
  reg [27:0] add_sig;
  reg [26:0] norm_sig;
  integer shift_amt;
  integer norm_count;
  begin
    sign_a = a_bits[31];
    sign_b = b_bits[31];
    exp_a_bits = a_bits[30:23];
    exp_b_bits = b_bits[30:23];
    sig_a = (exp_a_bits == 8'b0) ? {1'b0, a_bits[22:0]}
                                  : {1'b1, a_bits[22:0]};
    sig_b = (exp_b_bits == 8'b0) ? {1'b0, b_bits[22:0]}
                                  : {1'b1, b_bits[22:0]};
    exp_a = (exp_a_bits == 8'b0) ? -12'sd126
                                  : ({4'b0, exp_a_bits} - 12'sd127);
    exp_b = (exp_b_bits == 8'b0) ? -12'sd126
                                  : ({4'b0, exp_b_bits} - 12'sd127);

    if (a_bits[30:0] == 31'b0) begin
      fp32_add_bits = b_bits;
    end else if (b_bits[30:0] == 31'b0) begin
      fp32_add_bits = a_bits;
    end else if (exp_a_bits == 8'hff || exp_b_bits == 8'hff) begin
      fp32_add_bits = 32'h7fc0_0000;
    end else begin
      if ((exp_b > exp_a) || ((exp_b == exp_a) && (sig_b > sig_a))) begin
        large_sign = sign_b;
        small_sign = sign_a;
        large_exp = exp_b;
        large_sig = {sig_b, 3'b0};
        shift_amt = $signed({{20{exp_b[11]}}, exp_b})
                  - $signed({{20{exp_a[11]}}, exp_a});
        small_sig = rshift_sticky27({sig_a, 3'b0}, shift_amt);
      end else begin
        large_sign = sign_a;
        small_sign = sign_b;
        large_exp = exp_a;
        large_sig = {sig_a, 3'b0};
        shift_amt = $signed({{20{exp_a[11]}}, exp_a})
                  - $signed({{20{exp_b[11]}}, exp_b});
        small_sig = rshift_sticky27({sig_b, 3'b0}, shift_amt);
      end

      if (large_sign == small_sign) begin
        add_sig = {1'b0, large_sig} + {1'b0, small_sig};
        if (add_sig[27]) begin
          norm_sig = {add_sig[27:2], |add_sig[1:0]};
          large_exp = large_exp + 12'sd1;
        end else begin
          norm_sig = add_sig[26:0];
        end
        fp32_add_bits = fp32_pack_from_grs(large_sign, large_exp, norm_sig);
      end else if (large_sig == small_sig) begin
        fp32_add_bits = 32'b0;
      end else begin
        norm_sig = large_sig - small_sig;
        for (norm_count = 0; norm_count < 24;
             norm_count = norm_count + 1) begin
          if (!norm_sig[26] && (large_exp > -12'sd126)) begin
            norm_sig = norm_sig << 1;
            large_exp = large_exp - 12'sd1;
          end
        end
        fp32_add_bits = fp32_pack_from_grs(large_sign, large_exp, norm_sig);
      end
    end
  end
endfunction

function [15:0] sanitize_bf16;
  input [15:0] value;
  begin
    if ((value[14:7] == 8'hff) && (value[6:0] != 7'b0))
      sanitize_bf16 = 16'h0000;
    else if ((value[14:0] == 15'h7f80))
      sanitize_bf16 = value[15] ? 16'hff7f : 16'h7f7f;
    else
      sanitize_bf16 = value;
  end
endfunction

function [17:0] rshift_rne_fine;
  input [17:0] value;
  input [2:0] amount;
  input coarse_guard;
  input coarse_sticky;
  input force_zero;
  reg [17:0] quotient;
  reg guard_bit;
  reg sticky_bit;
  begin
    quotient = value;
    guard_bit = coarse_guard;
    sticky_bit = coarse_sticky;
    case (amount)
      3'd0: begin
        quotient = value;
      end
      3'd1: begin
        quotient = value >> 1;
        guard_bit = value[0];
        sticky_bit = coarse_guard | coarse_sticky;
      end
      3'd2: begin
        quotient = value >> 2;
        guard_bit = value[1];
        sticky_bit = value[0] | coarse_guard | coarse_sticky;
      end
      3'd3: begin
        quotient = value >> 3;
        guard_bit = value[2];
        sticky_bit = (|value[1:0]) | coarse_guard | coarse_sticky;
      end
      3'd4: begin
        quotient = value >> 4;
        guard_bit = value[3];
        sticky_bit = (|value[2:0]) | coarse_guard | coarse_sticky;
      end
      3'd5: begin
        quotient = value >> 5;
        guard_bit = value[4];
        sticky_bit = (|value[3:0]) | coarse_guard | coarse_sticky;
      end
      3'd6: begin
        quotient = value >> 6;
        guard_bit = value[5];
        sticky_bit = (|value[4:0]) | coarse_guard | coarse_sticky;
      end
      3'd7: begin
        quotient = value >> 7;
        guard_bit = value[6];
        sticky_bit = (|value[5:0]) | coarse_guard | coarse_sticky;
      end
    endcase
    rshift_rne_fine = force_zero
                    ? 18'b0
                    : quotient
                      + (guard_bit && (sticky_bit || quotient[0]));
  end
endfunction

function signed [20:0] align_product_signed;
  input [17:0] value;
  input [2:0] amount;
  input coarse_guard;
  input coarse_sticky;
  input force_zero;
  input sign;
  reg [17:0] aligned;
  reg signed [20:0] signed_aligned;
  begin
    aligned = rshift_rne_fine(value, amount, coarse_guard,
                              coarse_sticky, force_zero);
    signed_aligned = {3'b0, aligned};
    if (sign)
      signed_aligned = -signed_aligned;
    align_product_signed = signed_aligned;
  end
endfunction

function [31:0] rshift_rne;
  input [31:0] value;
  input integer amount;
  reg [31:0] quotient;
  reg [31:0] remainder;
  reg [31:0] half;
  reg [31:0] mask;
  begin
    if (amount <= 0) begin
      rshift_rne = value;
    end else if (amount >= 31) begin
      rshift_rne = 32'b0;
    end else begin
      quotient = value >> amount;
      mask = (32'h1 << amount) - 32'h1;
      remainder = value & mask;
      half = 32'h1 << (amount - 1);
      rshift_rne = quotient
                 + ((remainder > half)
                    || ((remainder == half) && quotient[0]));
    end
  end
endfunction

function [4:0] msb_index24;
  input [23:0] value;
  integer idx;
  begin
    msb_index24 = 5'b0;
    for (idx = 0; idx < 24; idx = idx + 1) begin
      if (value[idx])
        msb_index24 = idx[4:0];
    end
  end
endfunction

function [15:0] normalize_sum_to_bf16;
  input signed [23:0] sum;
  input signed [9:0] max_exp;
  reg sign;
  reg [23:0] mag;
  reg [4:0] msb;
  reg [31:0] rounded;
  reg [8:0] sig;
  reg [8:0] sub_sig;
  integer exp_field;
  integer shift;
  begin
    if (sum == 24'sd0) begin
      normalize_sum_to_bf16 = 16'h0000;
    end else begin
      sign = sum[23];
      mag = sign ? -sum : sum;
      msb = msb_index24(mag);
      exp_field = $signed({{22{max_exp[9]}}, max_exp})
                + $signed({27'b0, msb}) - 32'sd7;

      if (exp_field >= 255) begin
        normalize_sum_to_bf16 = sign ? 16'hff7f : 16'h7f7f;
      end else if (exp_field <= 0) begin
        shift = max_exp + 6;
        if (shift >= 0)
          rounded = {8'b0, mag} << shift;
        else
          rounded = rshift_rne({8'b0, mag}, -shift);
        sub_sig = rounded[8:0];
        if (sub_sig >= 9'd128)
          normalize_sum_to_bf16 = {sign, 8'h01, 7'h00};
        else
          normalize_sum_to_bf16 = {sign, 8'h00, sub_sig[6:0]};
      end else begin
        if (msb > 7)
          rounded = rshift_rne({8'b0, mag}, msb - 7);
        else
          rounded = {8'b0, mag} << (7 - msb);

        sig = rounded[8:0];
        if (sig >= 9'd256) begin
          sig = {1'b0, sig[8:1]};
          exp_field = exp_field + 1;
        end

        if (exp_field >= 255)
          normalize_sum_to_bf16 = sign ? 16'hff7f : 16'h7f7f;
        else
          normalize_sum_to_bf16 = {sign, exp_field[7:0], sig[6:0]};
      end
    end
end
endfunction

// Preserve the complete 24-bit dot sum in an FP32 container before BF22
// rounding. Normal finite dot products fit exactly because s4_sum itself has
// at most 24 significant bits.
function [31:0] normalize_sum_to_fp32;
  input signed [23:0] sum;
  input signed [9:0] max_exp;
  reg sign;
  reg [23:0] mag;
  reg [4:0] msb;
  reg [47:0] normalized;
  reg [47:0] subnormal;
  integer exp_field;
  integer shift;
  begin
    if (sum == 24'sd0) begin
      normalize_sum_to_fp32 = 32'b0;
    end else begin
      sign = sum[23];
      mag = sign ? -sum : sum;
      msb = msb_index24(mag);
      exp_field = $signed({{22{max_exp[9]}}, max_exp})
                + $signed({27'b0, msb}) - 32'sd7;

      if (exp_field >= 255) begin
        normalize_sum_to_fp32 = {sign, 8'hfe, 23'h7fffff};
      end else if (exp_field <= 0) begin
        // FP32 subnormal fraction unit is 2^-149. The matching BF16 helper
        // uses max_exp+6 for its 2^-133 fraction, hence +22 here.
        shift = $signed({{22{max_exp[9]}}, max_exp}) + 32'sd22;
        if (shift >= 0)
          subnormal = {24'b0, mag} << shift;
        else
          subnormal = {16'b0, rshift_rne({8'b0, mag}, -shift)};
        if (subnormal >= (48'b1 << 23))
          normalize_sum_to_fp32 = {sign, 8'h01, 23'b0};
        else
          normalize_sum_to_fp32 = {sign, 8'h00, subnormal[22:0]};
      end else begin
        normalized = {24'b0, mag} << (23 - msb);
        normalize_sum_to_fp32 = {sign, exp_field[7:0],
                                 normalized[22:0]};
      end
    end
  end
endfunction

always @(posedge clk or negedge rst_b) begin
  if (!rst_b) begin
    s0_valid <= 1'b0;
    s1_valid <= 1'b0;
    s2_valid <= 1'b0;
    s3_valid <= 1'b0;
    s4_valid <= 1'b0;
    s5_valid <= 1'b0;
    s6_valid <= 1'b0;
    s6_bf16 <= 16'b0;
    s6_bf22_bits <= 32'b0;
    s0_rsum_enable <= 1'b0;
    s1_rsum_enable <= 1'b0;
    s2_rsum_enable <= 1'b0;
    s3_rsum_enable <= 1'b0;
    s4_rsum_enable <= 1'b0;
    s5_rsum_enable <= 1'b0;
    s6_rsum_enable <= 1'b0;
    s0_rsum_first <= 1'b0;
    s1_rsum_first <= 1'b0;
    s2_rsum_first <= 1'b0;
    s3_rsum_first <= 1'b0;
    s4_rsum_first <= 1'b0;
    s5_rsum_first <= 1'b0;
    s6_rsum_first <= 1'b0;
    s0_rsum_last <= 1'b0;
    s1_rsum_last <= 1'b0;
    s2_rsum_last <= 1'b0;
    s3_rsum_last <= 1'b0;
    s4_rsum_last <= 1'b0;
    s5_rsum_last <= 1'b0;
    s6_rsum_last <= 1'b0;
    rsum_accum_q <= 32'b0;
    rsum_output_valid_q <= 1'b0;
    rsum_output_bf22_q <= 32'b0;
    rsum_output_bf16_q <= 16'b0;
  end else begin
    s0_valid <= in_valid;
    s1_valid <= s0_valid;
    s2_valid <= s1_valid;
    s3_valid <= s2_valid;
    s4_valid <= s3_valid;
    s5_valid <= reduction_valid;
    s6_valid <= s5_valid;
    s0_rsum_enable <= rsum_enable_i;
    s1_rsum_enable <= s0_rsum_enable;
    s2_rsum_enable <= s1_rsum_enable;
    s3_rsum_enable <= s2_rsum_enable;
    s4_rsum_enable <= s3_rsum_enable;
    s5_rsum_enable <= reduction_rsum_enable;
    s6_rsum_enable <= s5_rsum_enable;
    s0_rsum_first <= rsum_first_i;
    s1_rsum_first <= s0_rsum_first;
    s2_rsum_first <= s1_rsum_first;
    s3_rsum_first <= s2_rsum_first;
    s4_rsum_first <= s3_rsum_first;
    s5_rsum_first <= reduction_rsum_first;
    s6_rsum_first <= s5_rsum_first;
    s0_rsum_last <= rsum_last_i;
    s1_rsum_last <= s0_rsum_last;
    s2_rsum_last <= s1_rsum_last;
    s3_rsum_last <= s2_rsum_last;
    s4_rsum_last <= s3_rsum_last;
    s5_rsum_last <= reduction_rsum_last;
    s6_rsum_last <= s5_rsum_last;

    rsum_output_valid_q <= 1'b0;
    if (s6_valid && s6_rsum_enable) begin
      rsum_accum_q <= rsum_next_bits;
      if (s6_rsum_last) begin
        rsum_output_bf22_q <= rsum_next_bits;
        rsum_output_bf16_q <= rsum_next_bf16_bits[31:16];
        rsum_output_valid_q <= 1'b1;
      end
    end

    for (i = 0; i < LANES; i = i + 1) begin
      s0_bf16[i] <= ingress_activation[i];
      s0_int8[i] <= int8_vec_i[i*8 +: 8];
      s0_weight_bf16[i] <= ingress_weight[i];
      s0_activation_nonzero[i] <= |ingress_activation[i][14:0];
      s0_weight_nonzero[i] <= weight_bf16_mode_i
        ? (|ingress_weight[i][14:0]) : (|int8_vec_i[i*8 +: 8]);
      s0_weight_exp_external[i] <= weight_exp_vec_i[i*8 +: 8];
      s0_external_product[i] <= external_product_vec_i[i*16 +: 16];
      s0_external_product_sign[i] <= external_product_sign_i[i];
    end
    s0_weight_bf16_mode <= weight_bf16_mode_i;

    for (i = 0; i < LANES; i = i + 1) begin
      s1_prod[i] <= product_comb[i];
      s1_sign[i] <= sign_comb[i];
      s1_exp[i] <= product_exp_comb[i*10 +: 10];
      s1_exp_valid[i] <= product_exp_valid_comb[i];
    end

    s2_max_exp <= max_exp_comb;
    for (i = 0; i < LANES; i = i + 1) begin
      s2_prod[i] <= PARALLEL_MAX_SHIFT ? parallel_product[i] : s1_prod[i];
      s2_sign[i] <= PARALLEL_MAX_SHIFT ? parallel_sign[i] : s1_sign[i];
      s2_shift[i] <= parallel_shift[i*11+:11];
      s2_exp[i] <= s1_exp[i];
    end

    s3_max_exp <= s2_max_exp;
    for (i = 0; i < LANES; i = i + 1) begin
      s3_fine[i] <= fine_comb[i];
      s3_force_zero[i] <= force_zero_comb[i];
      s3_sign[i] <= s2_sign[i];
      s3_coarse[i] <= coarse_comb[i];
      s3_coarse_guard[i] <= coarse_guard_comb[i];
      s3_coarse_sticky[i] <= coarse_sticky_comb[i];
    end

    s4_max_exp <= s3_max_exp;
    for (i = 0; i < LANES; i = i + 1) begin
      s4_lane[i] <= aligned_comb[i];
    end

    s5_max_exp <= reduction_exp;
    s5_sum <= s5_sum_next;

    s6_bf16 <= normalize_sum_to_bf16(s5_sum, s5_max_exp);
    s6_bf22_bits <= bf22_round_bits(
        normalize_sum_to_fp32(s5_sum, s5_max_exp));
  end
end

endmodule
