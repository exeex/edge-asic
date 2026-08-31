`timescale 1ns/1ps

// Output-side ACTU finalizer.  The RCP backend hands this block one compact,
// latency-aligned packet; this block owns all post-RCP arithmetic, result
// selection, softmax accumulation, and output pipeline state.
(* keep_hierarchy = "yes" *)
module edge_actu_finalizer #(
  parameter POST_STAGES = 4
) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire [2:0]  in_mode,
  input  wire [18:0] in_payload_bf19,
  input  wire [21:0] in_primary_bf22,
  input  wire [21:0] in_rcp_bf22,
  input  wire        in_sum_clear,
  output wire        out_valid,
  output wire [2:0]  out_mode,
  output wire [31:0] out_value,
  output wire        softmax_sum_valid,
  output wire [31:0] softmax_sum_value
);

localparam [2:0] EDGE_ACTU_MODE_EXP_ONLY = 3'd0;
localparam [2:0] EDGE_ACTU_MODE_SIGMOID  = 3'd2;
localparam [2:0] EDGE_ACTU_MODE_SILU     = 3'd3;
localparam [2:0] EDGE_ACTU_MODE_TANH     = 3'd4;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX  = 3'd5;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX_NORMALIZE = 3'd7;
localparam integer VALUE_PIPE_LAST = POST_STAGES - 3;

reg [POST_STAGES-1:0] valid_pipe;
reg [2:0]             mode_pipe [0:POST_STAGES-1];
reg [31:0]            value_pipe [0:POST_STAGES-1];
reg [2:0]             mul_mode_q;
reg [18:0]            mul_payload_q;
reg [31:0]            mul_direct_q;
reg [31:0]            mul_softmax_product_q;
reg                    mul_sign_q;
reg                    mul_zero_q;
reg                    mul_special_q;
reg signed [11:0]      mul_exp_q;
reg [21:0]             mul_product_q;
reg [2:0]             final_mode_q;
reg [18:0]            final_payload_q;
reg [18:0]            final_sigmoid_bf19_q;
reg [31:0]            final_direct_q;
reg [31:0]            final_softmax_product_q;
reg [21:0]            softmax_sum_q;
integer stage;

wire [31:0] primary_bits;
wire [31:0] rcp_bits;
wire [18:0] primary_bf19;
wire [18:0] rcp_bf19;
wire [18:0] sigmoid_bf19;
wire [10:0] sigmoid_sig_a;
wire [10:0] sigmoid_sig_b;
wire        sigmoid_mul_sign;
wire        sigmoid_mul_zero;
wire        sigmoid_mul_special;
wire signed [11:0] sigmoid_mul_exp;
wire [21:0] sigmoid_mul_product;
wire [31:0] silu_product_bits;
wire [31:0] tanh_signed_bits;
wire [31:0] exp_result_bits;
wire [31:0] rcp_result_bits;
wire [31:0] sigmoid_result_bits;
wire [31:0] silu_result_bits;
wire [31:0] tanh_result_bits;
wire [31:0] softmax_result_bits;
wire [31:0] softmax_product_bits;
wire [31:0] softmax_normalize_bits;
wire [31:0] final_direct_bits;
wire [31:0] stage0_result_bits;
wire [21:0] softmax_sum_next_bf22;

assign out_valid = valid_pipe[POST_STAGES-1];
assign out_mode = mode_pipe[POST_STAGES-1];
assign out_value = value_pipe[VALUE_PIPE_LAST];

function [31:0] bf16_round_bits;
  input [31:0] bits;
  reg [15:0] rounded;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      rounded = 16'h7fc0;
    end else begin
      rounded = bits[31:16] + {15'b0, (bits[15] && (|bits[14:0] || bits[16]))};
      if ((rounded == 16'h0000) && bits[31])
        rounded = 16'h8000;
    end
    bf16_round_bits = {rounded, 16'h0000};
  end
endfunction

function [21:0] bf22_add_positive;
  input [21:0] a;
  input [21:0] b;
  reg [7:0] a_exp;
  reg [7:0] b_exp;
  reg [7:0] large_exp;
  reg [7:0] small_exp;
  reg [13:0] a_sig;
  reg [13:0] b_sig;
  reg [13:0] large_main;
  reg [14:0] rounded_main;
  reg [18:0] large_sig;
  reg [18:0] small_sig;
  reg [18:0] norm_sig;
  reg [19:0] sum;
  reg sticky;
  integer shift;
  begin
    a_exp = a[20:13];
    b_exp = b[20:13];
    a_sig = (a_exp == 0) ? {1'b0, a[12:0]} : {1'b1, a[12:0]};
    b_sig = (b_exp == 0) ? {1'b0, b[12:0]} : {1'b1, b[12:0]};
    if (a_sig == 0) begin
      bf22_add_positive = b;
    end else if (b_sig == 0) begin
      bf22_add_positive = a;
    end else begin
      if ((b_exp > a_exp) || ((b_exp == a_exp) && (b_sig > a_sig))) begin
        large_exp = (b_exp == 0) ? 8'd1 : b_exp;
        small_exp = (a_exp == 0) ? 8'd1 : a_exp;
        large_sig = {b_sig, 5'b0};
        shift = {24'b0, large_exp} - {24'b0, small_exp};
        if (shift >= 19)
          small_sig = {18'b0, |a_sig};
        else if (shift == 0)
          small_sig = {a_sig, 5'b0};
        else begin
          sticky = |({a_sig, 5'b0} & ((19'b1 << shift) - 19'b1));
          small_sig = ({a_sig, 5'b0} >> shift) | {18'b0, sticky};
        end
      end else begin
        large_exp = (a_exp == 0) ? 8'd1 : a_exp;
        small_exp = (b_exp == 0) ? 8'd1 : b_exp;
        large_sig = {a_sig, 5'b0};
        shift = {24'b0, large_exp} - {24'b0, small_exp};
        if (shift >= 19)
          small_sig = {18'b0, |b_sig};
        else if (shift == 0)
          small_sig = {b_sig, 5'b0};
        else begin
          sticky = |({b_sig, 5'b0} & ((19'b1 << shift) - 19'b1));
          small_sig = ({b_sig, 5'b0} >> shift) | {18'b0, sticky};
        end
      end
      sum = {1'b0, large_sig} + {1'b0, small_sig};
      if (sum[19]) begin
        norm_sig = {sum[19:2], |sum[1:0]};
        large_exp = large_exp + 1'b1;
      end else begin
        norm_sig = sum[18:0];
      end
      large_main = norm_sig[18:5];
      rounded_main = {1'b0, large_main} +
                     (norm_sig[4] && (|norm_sig[3:0] || large_main[0]));
      if ((large_exp == 8'hff) ||
          ((large_exp == 8'hfe) && rounded_main[14])) begin
        bf22_add_positive = {1'b0, 8'hfe, 13'h1fff};
      end else if (rounded_main[14]) begin
        bf22_add_positive = {1'b0, large_exp + 1'b1,
                             rounded_main[13:1]};
      end else begin
        bf22_add_positive = {1'b0, large_exp, rounded_main[12:0]};
      end
    end
  end
endfunction

function [31:0] bf19_round_bits;
  input [31:0] bits;
  reg [31:0] rounded_bits;
  reg [31:0] bias;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      bf19_round_bits = 32'h7fc0_0000;
    end else begin
      bias = 32'h0000_0fff + {31'b0, bits[13]};
      rounded_bits = (bits + bias) & 32'hffff_e000;
      bf19_round_bits = rounded_bits;
    end
  end
endfunction

function [31:0] bf22_round_bits;
  input [31:0] bits;
  reg [31:0] rounded_bits;
  reg [31:0] bias;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      bf22_round_bits = 32'h7fc0_0000;
    end else begin
      bias = 32'h0000_01ff + {31'b0, bits[10]};
      rounded_bits = (bits + bias) & 32'hffff_fc00;
      bf22_round_bits = rounded_bits;
    end
  end
endfunction

// Native BF22-to-BF19 conversion for the first fused multiply.  Keeping this
// boundary compact prevents the 11x11 significand datapath from expanding
// back into a generic FP32 multiplier/packer in synthesis.
function [18:0] bf22_to_bf19;
  input [21:0] bits;
  reg [18:0] rounded;
  begin
    if ((bits[20:13] == 8'hff) && (bits[12:0] != 13'b0)) begin
      bf22_to_bf19 = {1'b0, 8'hff, 10'h200};
    end else begin
      rounded = {1'b0, bits[20:3]} +
                {18'b0, bits[2] && (|bits[1:0] || bits[3])};
      bf22_to_bf19 = {bits[21], rounded[17:0]};
    end
  end
endfunction

// Cycle two of the native BF19 multiplier: normalize the registered 11x11
// product, round once, and assemble the compact sign/exponent/fraction result.
function [18:0] bf19_pack_product;
  input sign_z;
  input zero_z;
  input special_z;
  input signed [11:0] exp_in;
  input [21:0] product;
  reg [10:0] main;
  reg guard_bit;
  reg sticky_bit;
  reg [11:0] rounded;
  reg signed [11:0] exp_z;
  reg signed [12:0] biased_exp;
  begin
    exp_z = exp_in;
    if (zero_z) begin
      bf19_pack_product = {sign_z, 18'b0};
    end else if (special_z) begin
      bf19_pack_product = {1'b0, 8'hff, 10'h200};
    end else begin
      if (product[21]) begin
        main = product[21:11];
        guard_bit = product[10];
        sticky_bit = |product[9:0];
        exp_z = exp_z + 12'sd1;
      end else begin
        main = product[20:10];
        guard_bit = product[9];
        sticky_bit = |product[8:0];
      end
      rounded = {1'b0, main} +
                {11'b0, guard_bit && (sticky_bit || main[0])};
      exp_z = exp_z + {11'b0, rounded[11]};
      biased_exp = exp_z + 13'sd127;
      if ((product == 22'b0) || (exp_z < -12'sd126))
        bf19_pack_product = {sign_z, 18'b0};
      else if (biased_exp >= 13'sd255)
        bf19_pack_product = {sign_z, 8'hff, 10'b0};
      else
        bf19_pack_product = {sign_z, biased_exp[7:0],
                             rounded[11] ? rounded[10:1] : rounded[9:0]};
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
                              rounded[24] ? rounded[23:1] : rounded[22:0]};
    end
  end
endfunction

function [31:0] fp32_mul_bits;
  input [31:0] a_bits;
  input [31:0] b_bits;
  reg        sign_z;
  reg [7:0]  exp_a_bits;
  reg [7:0]  exp_b_bits;
  reg [23:0] sig_a;
  reg [23:0] sig_b;
  reg signed [11:0] exp_a;
  reg signed [11:0] exp_b;
  reg signed [11:0] exp_z;
  reg [47:0] product;
  reg [26:0] sig_grs;
  begin
    sign_z = a_bits[31] ^ b_bits[31];
    exp_a_bits = a_bits[30:23];
    exp_b_bits = b_bits[30:23];
    if (a_bits[30:0] == 31'b0 || b_bits[30:0] == 31'b0) begin
      fp32_mul_bits = {sign_z, 31'b0};
    end else if (exp_a_bits == 8'hff || exp_b_bits == 8'hff) begin
      fp32_mul_bits = 32'h7fc0_0000;
    end else begin
      sig_a = (exp_a_bits == 8'b0) ? {1'b0, a_bits[22:0]} :
                                      {1'b1, a_bits[22:0]};
      sig_b = (exp_b_bits == 8'b0) ? {1'b0, b_bits[22:0]} :
                                      {1'b1, b_bits[22:0]};
      exp_a = (exp_a_bits == 8'b0) ? -12'sd126 : ({4'b0, exp_a_bits} - 12'sd127);
      exp_b = (exp_b_bits == 8'b0) ? -12'sd126 : ({4'b0, exp_b_bits} - 12'sd127);
      product = sig_a * sig_b;
      if (product[47]) begin
        exp_z = exp_a + exp_b + 12'sd1;
        sig_grs = {product[47:24], product[23], product[22], |product[21:0]};
      end else begin
        exp_z = exp_a + exp_b;
        sig_grs = {product[46:23], product[22], product[21], |product[20:0]};
      end
      fp32_mul_bits = fp32_pack_from_grs(sign_z, exp_z, sig_grs);
    end
  end
endfunction

assign primary_bits = {in_primary_bf22, 10'b0};
assign rcp_bits = {in_rcp_bf22, 10'b0};
assign primary_bf19 = bf22_to_bf19(in_primary_bf22);
assign rcp_bf19 = bf22_to_bf19(in_rcp_bf22);
assign sigmoid_sig_a = (primary_bf19[17:10] == 8'b0) ?
                       {1'b0, primary_bf19[9:0]} :
                       {1'b1, primary_bf19[9:0]};
assign sigmoid_sig_b = (rcp_bf19[17:10] == 8'b0) ?
                       {1'b0, rcp_bf19[9:0]} :
                       {1'b1, rcp_bf19[9:0]};
assign sigmoid_mul_sign = primary_bf19[18] ^ rcp_bf19[18];
assign sigmoid_mul_zero = (primary_bf19[17:0] == 18'b0) ||
                          (rcp_bf19[17:0] == 18'b0);
assign sigmoid_mul_special = (primary_bf19[17:10] == 8'hff) ||
                             (rcp_bf19[17:10] == 8'hff);
assign sigmoid_mul_exp =
    ((primary_bf19[17:10] == 8'b0) ? -12'sd126 :
     ({4'b0, primary_bf19[17:10]} - 12'sd127)) +
    ((rcp_bf19[17:10] == 8'b0) ? -12'sd126 :
     ({4'b0, rcp_bf19[17:10]} - 12'sd127));
assign sigmoid_mul_product = sigmoid_sig_a * sigmoid_sig_b;
assign sigmoid_bf19 = bf19_pack_product(mul_sign_q, mul_zero_q,
                                        mul_special_q, mul_exp_q,
                                        mul_product_q);
assign silu_product_bits = bf22_round_bits(fp32_mul_bits(
                            {final_payload_q, 13'b0},
                            {final_sigmoid_bf19_q, 13'b0}));
assign tanh_signed_bits = {final_payload_q[18],
                           final_sigmoid_bf19_q[17:0], 13'b0};
assign exp_result_bits = bf16_round_bits(primary_bits);
assign rcp_result_bits = bf16_round_bits(rcp_bits);
assign sigmoid_result_bits = bf16_round_bits({final_sigmoid_bf19_q, 13'b0});
assign silu_result_bits = bf16_round_bits(silu_product_bits);
assign tanh_result_bits = bf16_round_bits(tanh_signed_bits);
assign softmax_result_bits = bf16_round_bits(primary_bits);
assign softmax_product_bits = bf22_round_bits(fp32_mul_bits(
                                  {in_payload_bf19, 13'b0},
                                  bf19_round_bits(rcp_bits)));
assign softmax_normalize_bits = bf16_round_bits(final_softmax_product_q);
assign final_direct_bits = ((in_mode == EDGE_ACTU_MODE_EXP_ONLY) ||
                            (in_mode == EDGE_ACTU_MODE_SOFTMAX)) ?
                           exp_result_bits : rcp_result_bits;
assign softmax_sum_next_bf22 = bf22_add_positive(softmax_sum_q,
                                                 in_primary_bf22);
assign softmax_sum_valid = in_valid && (in_mode == EDGE_ACTU_MODE_SOFTMAX);
assign softmax_sum_value = {softmax_sum_next_bf22, 10'b0};
assign stage0_result_bits = (final_mode_q == EDGE_ACTU_MODE_SIGMOID) ?
                            sigmoid_result_bits :
                            ((final_mode_q == EDGE_ACTU_MODE_SILU) ? silu_result_bits :
                             ((final_mode_q == EDGE_ACTU_MODE_TANH) ? tanh_result_bits :
                              ((final_mode_q == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
                               softmax_normalize_bits : final_direct_q)));

always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    softmax_sum_q <= 22'b0;
    mul_mode_q <= 3'b0;
    mul_payload_q <= 19'b0;
    mul_direct_q <= 32'b0;
    mul_softmax_product_q <= 32'b0;
    mul_sign_q <= 1'b0;
    mul_zero_q <= 1'b0;
    mul_special_q <= 1'b0;
    mul_exp_q <= 12'sd0;
    mul_product_q <= 22'b0;
    final_mode_q <= 3'b0;
    final_payload_q <= 19'b0;
    final_sigmoid_bf19_q <= 19'b0;
    final_direct_q <= 32'b0;
    final_softmax_product_q <= 32'b0;
    valid_pipe <= {POST_STAGES{1'b0}};
    for (stage = 0; stage < POST_STAGES; stage = stage + 1) begin
      mode_pipe[stage] <= 3'b0;
      value_pipe[stage] <= 32'b0;
    end
  end else begin
    if (in_sum_clear)
      softmax_sum_q <= 22'b0;
    else if (softmax_sum_valid)
      softmax_sum_q <= softmax_sum_next_bf22;
    mul_mode_q <= in_mode;
    mul_payload_q <= in_payload_bf19;
    mul_direct_q <= final_direct_bits;
    mul_softmax_product_q <= softmax_product_bits;
    mul_sign_q <= sigmoid_mul_sign;
    mul_zero_q <= sigmoid_mul_zero;
    mul_special_q <= sigmoid_mul_special;
    mul_exp_q <= sigmoid_mul_exp;
    mul_product_q <= sigmoid_mul_product;
    final_mode_q <= mul_mode_q;
    final_payload_q <= mul_payload_q;
    final_sigmoid_bf19_q <= sigmoid_bf19;
    final_direct_q <= mul_direct_q;
    final_softmax_product_q <= mul_softmax_product_q;
    valid_pipe[0] <= in_valid;
    mode_pipe[0] <= in_mode;
    value_pipe[0] <= stage0_result_bits;

    for (stage = 1; stage < POST_STAGES; stage = stage + 1) begin
      valid_pipe[stage] <= valid_pipe[stage - 1];
      mode_pipe[stage] <= mode_pipe[stage - 1];
    end
    for (stage = 1; stage <= VALUE_PIPE_LAST; stage = stage + 1) begin
      value_pipe[stage] <= value_pipe[stage - 1];
    end
  end
end

endmodule
