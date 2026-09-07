`timescale 1ns/1ps

// West-side ACTU frontend. EXP and the fused native-BF22 numerator /
// denominator transform stay behind a registered physical boundary.
(* keep_hierarchy = "yes" *)
module edge_actu_exp_frontend (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire        in_last,
  input  wire [2:0]  in_mode,
  input  wire [15:0] in_value_bf16,
  input  wire [21:0] in_scalar_bf22,
  input  wire        in_sum_clear,
  input  wire exp_underflow,
  input wire signed [9:0] exp2_k,
  input wire [14:0] exp_hi,
  input wire [20:0] exp_residual_product,
  output reg         out_valid,
  output reg         out_last,
  output reg  [2:0]  out_mode,
  output reg  [18:0] out_payload_bf19,
  output reg         out_sum_clear,
  output reg  [21:0] out_primary_bf22,
  output reg  [2:0]  out_primary_class,
  output reg  [2:0]  out_divisor_class,
  output reg  [2:0]  out_payload_class,
  output reg  [21:0] out_divisor_bf22
);

// Class encoding: normal=0, zero=1, subnormal=2, infinity=4, NaN=5.
// Divisor class is consumed by the nonlinear core; primary/payload classes
// travel to the finalizer. Arithmetic and special-case priorities are unchanged.
wire [2:0] exp_class, input_class, scalar_class;
wire [2:0] den_class, add_class, numerator_class;
reg [2:0] exp_class_s0, exp_class_s1, exp_class_s2;
reg [2:0] payload_class_s0, payload_class_s1, payload_class_s2;
reg [2:0] scalar_class_s0, scalar_class_s1, scalar_class_s2;
reg [2:0] den_class_s2, add_class_s2;
edge_actu_bf22_classify classify_exp(exp_lut_bf22,exp_class);
edge_actu_bf22_classify classify_input({in_value_bf16,6'b0},input_class);
edge_actu_bf22_classify classify_scalar(in_scalar_bf22,scalar_class);
// The 1+e pack always emits exponent 127..129, including arbitrary raw bits.
assign den_class=3'd0;
wire [2:0] add_candidate_class;
edge_actu_bf22_classify classify_add(bypass_add_bf22_s2,add_candidate_class);
assign add_class=(bypass_add_raw_s1_q==0)?3'd1:add_candidate_class;
assign numerator_class=(tanh_num_raw_s2==0)?3'd1:3'd0;

localparam [2:0] EDGE_ACTU_MODE_RCP_ONLY = 3'd1;
localparam [2:0] EDGE_ACTU_MODE_SIGMOID = 3'd2;
localparam [2:0] EDGE_ACTU_MODE_SILU = 3'd3;
localparam [2:0] EDGE_ACTU_MODE_TANH = 3'd4;
localparam [2:0] EDGE_ACTU_MODE_RSQRT = 3'd6;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX_NORMALIZE = 3'd7;
localparam [21:0] BF22_ONE = 22'h0fe000;
localparam [18:0] BF22_ONE_EXT = {14'h2000, 5'b0};

wire [28:0] exp_product_q28;
wire [21:0] exp_packed_bf22;
wire [21:0] exp_lut_bf22;
wire [18:0] aligned_e_s1;
wire [19:0] den_raw_s1;
wire [18:0] tanh_num_raw_s1;
wire [4:0] tanh_num_lzc_s2;
wire [21:0] den_bf22_s2;
wire [21:0] tanh_num_bf22_s3;
wire [21:0] bypass_add_bf22_s2;
wire fused_sigmoid_s3;

reg         valid_s0;
reg         last_s0;
reg [2:0]   mode_s0;
reg [18:0]  payload_bf19_s0;
reg         sum_clear_s0;
reg [21:0]  exp_s0;
wire [21:0] value_bf22_s0 = {payload_bf19_s0, 3'b0};
reg [21:0]  scalar_bf22_s0;

reg         valid_s1;
reg         last_s1;
reg [2:0]   mode_s1;
reg [18:0]  payload_bf19_s1;
reg         sum_clear_s1;
reg [21:0]  exp_s1;
wire [21:0] value_bf22_s1 = {payload_bf19_s1, 3'b0};
reg [21:0]  scalar_bf22_s1;
reg [19:0]  den_raw_s1_q;
reg [18:0]  tanh_num_raw_s1_q;
reg [7:0]   bypass_add_exp_s1_q;
reg [19:0]  bypass_add_raw_s1_q;

reg         valid_s2;
reg         last_s2;
reg [2:0]   mode_s2;
reg [18:0]  payload_bf19_s2;
reg         sum_clear_s2;
reg [21:0]  exp_s2;
wire [21:0] value_bf22_s2 = {payload_bf19_s2, 3'b0};
reg [21:0]  scalar_bf22_s2;
reg [21:0]  den_s2;
reg [21:0]  bypass_add_s2;
reg [18:0]  tanh_num_raw_s2;
reg [4:0]   tanh_num_lzc_s2_q;

reg [7:0]   bypass_large_exp;
reg [7:0]   bypass_small_exp;
reg [13:0]  bypass_large_sig;
reg [13:0]  bypass_small_sig;
reg [18:0]  bypass_large_ext;
reg [18:0]  bypass_small_ext;
reg         bypass_sticky;
reg [19:0]  bypass_add_raw_s1;
reg [7:0]   bypass_add_exp_s1;
integer     bypass_shift;





// Align positive BF22 e to the 1.0 exponent with five GRS bits. Fused modes
// guarantee 0 <= e <= 1; values above one are clamped to the exact-one rail.
function [18:0] align_to_one_grs;
  input [21:0] e;
  reg [7:0] exp_bits;
  reg [13:0] sig;
  reg [18:0] ext;
  reg sticky;
  integer shift;
  begin
    exp_bits = e[20:13];
    sig = (exp_bits == 0) ? {1'b0, e[12:0]} : {1'b1, e[12:0]};
    ext = {sig, 5'b0};
    if (exp_bits >= 8'd127) begin
      align_to_one_grs = BF22_ONE_EXT;
    end else begin
      shift = {24'b0, 8'd127} - {24'b0, exp_bits};
      if (shift >= 19) begin
        align_to_one_grs = {18'b0, |sig};
      end else begin
        sticky = |(ext & ((19'b1 << shift) - 19'b1));
        align_to_one_grs = (ext >> shift) | {18'b0, sticky};
      end
    end
  end
endfunction

function [4:0] lzc19;
  input [18:0] value;
  begin
    casez (value)
      19'b1??????????????????: lzc19 = 5'd0;
      19'b01?????????????????: lzc19 = 5'd1;
      19'b001????????????????: lzc19 = 5'd2;
      19'b0001???????????????: lzc19 = 5'd3;
      19'b00001??????????????: lzc19 = 5'd4;
      19'b000001?????????????: lzc19 = 5'd5;
      19'b0000001????????????: lzc19 = 5'd6;
      19'b00000001???????????: lzc19 = 5'd7;
      19'b000000001??????????: lzc19 = 5'd8;
      19'b0000000001?????????: lzc19 = 5'd9;
      19'b00000000001????????: lzc19 = 5'd10;
      19'b000000000001???????: lzc19 = 5'd11;
      19'b0000000000001??????: lzc19 = 5'd12;
      19'b00000000000001?????: lzc19 = 5'd13;
      19'b000000000000001????: lzc19 = 5'd14;
      19'b0000000000000001???: lzc19 = 5'd15;
      19'b00000000000000001??: lzc19 = 5'd16;
      19'b000000000000000001?: lzc19 = 5'd17;
      19'b0000000000000000001: lzc19 = 5'd18;
      default: lzc19 = 5'd19;
    endcase
  end
endfunction

function [21:0] pack_den_bf22;
  input [19:0] raw;
  reg [7:0] exp_bits;
  reg [18:0] norm;
  reg [13:0] main;
  reg [14:0] rounded;
  begin
    if (raw[19]) begin
      exp_bits = 8'd128;
      norm = {raw[19:2], |raw[1:0]};
    end else begin
      exp_bits = 8'd127;
      norm = raw[18:0];
    end
    main = norm[18:5];
    rounded = {1'b0, main} +
              (norm[4] && (|norm[3:0] || main[0]));
    if (rounded[14])
      pack_den_bf22 = {1'b0, exp_bits + 1'b1, rounded[13:1]};
    else
      pack_den_bf22 = {1'b0, exp_bits, rounded[12:0]};
  end
endfunction

function [21:0] pack_num_bf22;
  input [18:0] raw;
  input [4:0] leading_zeros;
  reg [18:0] norm;
  reg [13:0] main;
  reg [14:0] rounded;
  reg [7:0] exp_bits;
  begin
    begin // Unconditional numeric candidate; ZERO travels in numerator_class.
      norm = raw << leading_zeros;
      exp_bits = 8'd127 - {3'b0, leading_zeros};
      main = norm[18:5];
      rounded = {1'b0, main} +
                (norm[4] && (|norm[3:0] || main[0]));
      if (rounded[14])
        pack_num_bf22 = {1'b0, exp_bits + 1'b1, rounded[13:1]};
      else
        pack_num_bf22 = {1'b0, exp_bits, rounded[12:0]};
    end
  end
endfunction

function [21:0] pack_positive_add_bf22;
  input [19:0] raw;
  input [7:0] base_exp;
  reg [7:0] exp_bits;
  reg [18:0] norm;
  reg [13:0] main;
  reg [14:0] rounded;
  begin
    begin // Unconditional numeric candidate; ZERO travels in add_class.
      if (raw[19]) begin
        exp_bits = base_exp + 1'b1;
        norm = {raw[19:2], |raw[1:0]};
      end else begin
        exp_bits = base_exp;
        norm = raw[18:0];
      end
      main = norm[18:5];
      rounded = {1'b0, main} +
                (norm[4] && (|norm[3:0] || main[0]));
      if (exp_bits == 8'hff ||
          (exp_bits == 8'hfe && rounded[14]))
        pack_positive_add_bf22 = 22'h1fdfff;
      else if (rounded[14])
        pack_positive_add_bf22 = {1'b0, exp_bits + 1'b1,
                                  rounded[13:1]};
      else
        pack_positive_add_bf22 = {1'b0, exp_bits, rounded[12:0]};
    end
  end
endfunction

// Direct RSQRT uses positive x+epsilon. Perform only alignment/addition here;
// F2 owns normalization and RNE packing so no generic FP32 adder crosses the
// frontend/backend boundary.
// Equal exponents need no significand ordering: neither operand shifts and
// their unsigned sum is commutative. Keep the ordering mux off the fraction
// comparator path; exponent zero still uses its effective exponent of one.
always @* begin
  if (scalar_bf22_s0[20:13] > value_bf22_s0[20:13]) begin
    bypass_large_exp = (scalar_bf22_s0[20:13] == 0) ?
                       8'd1 : scalar_bf22_s0[20:13];
    bypass_small_exp = (value_bf22_s0[20:13] == 0) ?
                       8'd1 : value_bf22_s0[20:13];
    bypass_large_sig = (scalar_bf22_s0[20:13] == 0) ?
                       {1'b0, scalar_bf22_s0[12:0]} :
                       {1'b1, scalar_bf22_s0[12:0]};
    bypass_small_sig = (value_bf22_s0[20:13] == 0) ?
                       {1'b0, value_bf22_s0[12:0]} :
                       {1'b1, value_bf22_s0[12:0]};
  end else begin
    bypass_large_exp = (value_bf22_s0[20:13] == 0) ?
                       8'd1 : value_bf22_s0[20:13];
    bypass_small_exp = (scalar_bf22_s0[20:13] == 0) ?
                       8'd1 : scalar_bf22_s0[20:13];
    bypass_large_sig = (value_bf22_s0[20:13] == 0) ?
                       {1'b0, value_bf22_s0[12:0]} :
                       {1'b1, value_bf22_s0[12:0]};
    bypass_small_sig = (scalar_bf22_s0[20:13] == 0) ?
                       {1'b0, scalar_bf22_s0[12:0]} :
                       {1'b1, scalar_bf22_s0[12:0]};
  end
  bypass_large_ext = {bypass_large_sig, 5'b0};
  bypass_small_ext = {bypass_small_sig, 5'b0};
  bypass_shift = {24'b0, bypass_large_exp} -
                 {24'b0, bypass_small_exp};
  bypass_sticky = 1'b0;
  if (bypass_shift >= 19) begin
    bypass_small_ext = {18'b0, |bypass_small_sig};
  end else if (bypass_shift != 0) begin
    bypass_sticky = |(bypass_small_ext &
                      ((19'b1 << bypass_shift) - 19'b1));
    bypass_small_ext = (bypass_small_ext >> bypass_shift) |
                       {18'b0, bypass_sticky};
  end
  bypass_add_exp_s1 = bypass_large_exp;
  bypass_add_raw_s1 = {1'b0, bypass_large_ext} +
                      {1'b0, bypass_small_ext};
end

// F0: G6 already captured the lookup and residual multiplication.
assign exp_product_q28={exp_hi,14'b0}+{8'b0,exp_residual_product};
edge_actu_exp2_pack_q28_bf22 x_exp_pack (
  .exp2_k(exp2_k), .mant_product_q28(exp_product_q28),
  .value_bf22(exp_packed_bf22)
);
assign exp_lut_bf22 = exp_underflow ? 22'b0 : exp_packed_bf22;
assign aligned_e_s1 = align_to_one_grs(exp_s0);
assign den_raw_s1 = {1'b0, BF22_ONE_EXT} + {1'b0, aligned_e_s1};
// align_to_one_grs is proven <= ONE_EXT for all BF22 encodings.
assign tanh_num_raw_s1 = BF22_ONE_EXT - aligned_e_s1;
assign tanh_num_lzc_s2 = lzc19(tanh_num_raw_s1_q);
assign den_bf22_s2 = pack_den_bf22(den_raw_s1_q);
assign bypass_add_bf22_s2 = pack_positive_add_bf22(
                              bypass_add_raw_s1_q,
                              bypass_add_exp_s1_q);
assign tanh_num_bf22_s3 = pack_num_bf22(tanh_num_raw_s2,
                                        tanh_num_lzc_s2_q);
assign fused_sigmoid_s3 = (mode_s2 == EDGE_ACTU_MODE_SIGMOID) ||
                           (mode_s2 == EDGE_ACTU_MODE_SILU);

// Only packet validity and independently meaningful control pulses reset.
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    valid_s0 <= 1'b0;
    last_s0 <= 1'b0;
    sum_clear_s0 <= 1'b0;
    valid_s1 <= 1'b0;
    last_s1 <= 1'b0;
    sum_clear_s1 <= 1'b0;
    valid_s2 <= 1'b0;
    last_s2 <= 1'b0;
    sum_clear_s2 <= 1'b0;
    out_valid <= 1'b0;
    out_last <= 1'b0;
    out_sum_clear <= 1'b0;
  end else begin
    valid_s0 <= in_valid;
    last_s0 <= in_last;
    sum_clear_s0 <= in_sum_clear;
    valid_s1 <= valid_s0;
    last_s1 <= last_s0;
    sum_clear_s1 <= sum_clear_s0;
    valid_s2 <= valid_s1;
    last_s2 <= last_s1;
    sum_clear_s2 <= sum_clear_s1;
    out_valid <= valid_s2;
    out_last <= last_s2;
    out_sum_clear <= sum_clear_s2;
  end
end

// Feed-forward data and modes refill under the valid pipeline.
always @(posedge clk) begin
    // F0: EXP output boundary.
    mode_s0 <= in_mode;
    payload_bf19_s0 <= {in_value_bf16,3'b0};
    exp_s0 <= exp_lut_bf22;

    scalar_bf22_s0 <= in_scalar_bf22;

    // F1: shared alignment and parallel 1+e / 1-e raw arithmetic.
    mode_s1 <= mode_s0;
    payload_bf19_s1 <= payload_bf19_s0;
    exp_s1 <= exp_s0;

    scalar_bf22_s1 <= scalar_bf22_s0;
    den_raw_s1_q <= den_raw_s1;
    tanh_num_raw_s1_q <= tanh_num_raw_s1;
    bypass_add_exp_s1_q <= bypass_add_exp_s1;
    bypass_add_raw_s1_q <= bypass_add_raw_s1;

    // F2: denominator pack and numerator leading-zero detection.
    mode_s2 <= mode_s1;
    payload_bf19_s2 <= payload_bf19_s1;
    exp_s2 <= exp_s1;

    scalar_bf22_s2 <= scalar_bf22_s1;
    den_s2 <= den_bf22_s2;
    bypass_add_s2 <= bypass_add_bf22_s2;
    tanh_num_raw_s2 <= tanh_num_raw_s1_q;
    tanh_num_lzc_s2_q <= tanh_num_lzc_s2;

    // F3: numerator normalize/pack and native-BF22 frontend packet.
    out_mode <= mode_s2;
    out_payload_bf19 <= payload_bf19_s2;
    if (mode_s2 == EDGE_ACTU_MODE_RCP_ONLY)
      out_divisor_bf22 <= value_bf22_s2;
    else if (mode_s2 == EDGE_ACTU_MODE_RSQRT)
      // RSQRT's architectural domain is non-negative. Preserve a negative
      // source so the shared backend returns its invalid/zero result instead
      // of interpreting the magnitude as a positive operand.
      out_divisor_bf22 <= value_bf22_s2[21] ? value_bf22_s2 : bypass_add_s2;
    else if (mode_s2 == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE)
      out_divisor_bf22 <= scalar_bf22_s2;
    else
      out_divisor_bf22 <= den_s2;
    if (mode_s2 == EDGE_ACTU_MODE_TANH)
      out_primary_bf22 <= tanh_num_bf22_s3;
    else if (fused_sigmoid_s3)
      out_primary_bf22 <= payload_bf19_s2[18] ? exp_s2 : BF22_ONE;
    else
      out_primary_bf22 <= exp_s2;
end

// Numerical class is payload: reset/clear cancellation remains owned by valid.
always @(posedge clk) begin
  exp_class_s0<=exp_class;exp_class_s1<=exp_class_s0;exp_class_s2<=exp_class_s1;
  payload_class_s0<=input_class;payload_class_s1<=payload_class_s0;payload_class_s2<=payload_class_s1;
  scalar_class_s0<=scalar_class;scalar_class_s1<=scalar_class_s0;scalar_class_s2<=scalar_class_s1;
  den_class_s2<=den_class;add_class_s2<=add_class;
  out_payload_class<=payload_class_s2;
  if(mode_s2==EDGE_ACTU_MODE_RCP_ONLY)out_divisor_class<=payload_class_s2;
  else if(mode_s2==EDGE_ACTU_MODE_RSQRT)
    out_divisor_class<=value_bf22_s2[21] ? payload_class_s2 : add_class_s2;
  else if(mode_s2==EDGE_ACTU_MODE_SOFTMAX_NORMALIZE)out_divisor_class<=scalar_class_s2;
  else out_divisor_class<=den_class_s2;
  if(mode_s2==EDGE_ACTU_MODE_TANH)out_primary_class<=numerator_class;
  else if(fused_sigmoid_s3)out_primary_class<=payload_bf19_s2[18] ? exp_class_s2 : 3'd0;
  else out_primary_class<=exp_class_s2;
end

endmodule

// Sign-independent BF22 category. Exact zero-extension from BF16/BF19
// preserves the category; reserved encodings are never emitted.
module edge_actu_bf22_classify(input wire [21:0] value_bf22,output wire [2:0] value_class);
wire exponent_zero=(value_bf22[20:13]==0);
wire exponent_special=(&value_bf22[20:13]);
wire fraction_zero=(value_bf22[12:0]==0);
assign value_class=exponent_zero ? (fraction_zero ? 3'd1 : 3'd2) :
                   exponent_special ? (fraction_zero ? 3'd4 : 3'd5) : 3'd0;
endmodule
