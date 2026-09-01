`timescale 1ns/1ps

// Output-side ACTU finalizer.  The RCP backend hands this block one compact,
// latency-aligned packet; this block owns all post-RCP arithmetic, result
// selection, softmax accumulation, and output pipeline state.
(* keep_hierarchy = "yes" *)
module edge_actu_finalizer #(
  parameter POST_STAGES = 6
) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire        in_last,
  input  wire [2:0]  in_mode,
  input  wire [18:0] in_payload_bf19,
  input  wire [21:0] in_primary_bf22,
  input  wire [21:0] in_rcp_bf22,
  input  wire        in_sum_clear,
  output wire        out_valid,
  output wire [2:0]  out_mode,
  output wire [31:0] out_value,
  output wire        softmax_sum_valid,
  output wire        softmax_sum_done,
  output wire [31:0] softmax_sum_value
);

localparam [2:0] EDGE_ACTU_MODE_EXP_ONLY = 3'd0;
localparam [2:0] EDGE_ACTU_MODE_SIGMOID  = 3'd2;
localparam [2:0] EDGE_ACTU_MODE_SILU     = 3'd3;
localparam [2:0] EDGE_ACTU_MODE_TANH     = 3'd4;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX  = 3'd5;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX_NORMALIZE = 3'd7;
localparam integer OUTPUT_PIPE_LAST = POST_STAGES - 6;

reg [POST_STAGES-1:0] valid_pipe;
reg [2:0]             mode_pipe [0:POST_STAGES-1];
reg [31:0]            value_pipe [0:OUTPUT_PIPE_LAST];

// P0: pure backend/finalizer boundary relay.  No arithmetic is allowed on
// this edge; M1 consumes only these registered fields.
reg               relay_valid_q;
reg [2:0]         relay_mode_q;
reg [18:0]        relay_payload_bf19_q;
reg [21:0]        relay_primary_bf22_q;
reg [21:0]        relay_rcp_bf22_q;

// M1P: metadata aligned with the registered pair of 14x7 partial products.
reg [2:0]         mul1_partial_mode_q;
reg [18:0]        mul1_partial_payload_q;
reg [21:0]        mul1_partial_direct_q;
reg               mul1_partial_sign_q;
reg               mul1_partial_zero_q;
reg               mul1_partial_special_q;
reg signed [11:0] mul1_partial_exp_q;

// M1A: registered raw BF22 numerator/reciprocal product after partial add.
reg [2:0]         mul1_mode_q;
reg [18:0]        mul1_payload_q;
reg [21:0]        mul1_direct_q;
reg               mul1_sign_q;
reg               mul1_zero_q;
reg               mul1_special_q;
reg signed [11:0] mul1_exp_q;
reg [27:0]        mul1_product_q;

// M2: first product rounded once to BF22.
reg [2:0]  mul2_mode_q;
reg [18:0] mul2_payload_q;
reg [21:0] mul2_direct_q;
reg [21:0] mul2_product_bf22_q;

// M3P: metadata/bypass aligned with SiLU's second 14x7 partial pair.
reg [2:0]         mul3_partial_mode_q;
reg [21:0]        mul3_partial_bypass_bf22_q;
reg               mul3_partial_sign_q;
reg               mul3_partial_zero_q;
reg               mul3_partial_special_q;
reg signed [11:0] mul3_partial_exp_q;

// M3A: SiLU's second raw BF22 product or a mode-aligned bypass result.
reg [2:0]         final_mode_q;
reg [21:0]        final_bypass_bf22_q;
reg               mul3_sign_q;
reg               mul3_zero_q;
reg               mul3_special_q;
reg signed [11:0] mul3_exp_q;
reg [27:0]        mul3_product_q;

integer stage;

wire [21:0] mul1_lhs_bf22;
wire [21:0] direct_bf22;
wire [13:0] mul1_sig_a;
wire [13:0] mul1_sig_b;
wire        mul1_sign;
wire        mul1_zero;
wire        mul1_special;
wire signed [11:0] mul1_exp;
wire [27:0] mul1_product;
wire [21:0] mul1_product_bf22;

wire [21:0] mul3_lhs_bf22;
wire [13:0] mul3_sig_a;
wire [13:0] mul3_sig_b;
wire        mul3_sign;
wire        mul3_zero;
wire        mul3_special;
wire signed [11:0] mul3_exp;
wire [27:0] mul3_product;
wire [21:0] mul3_product_bf22;
wire [21:0] stage3_bypass_bf22;
wire [21:0] final_result_bf22;
wire [31:0] final_result_bits;
wire [21:0] softmax_sum_bf22;

assign out_valid = valid_pipe[POST_STAGES-1];
assign out_mode = mode_pipe[POST_STAGES-1];
assign out_value = value_pipe[OUTPUT_PIPE_LAST];

function [31:0] bf16_round_bits;
  input [31:0] bits;
  reg [15:0] rounded;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      rounded = 16'h7fc0;
    end else begin
      rounded = bits[31:16] +
                {15'b0, (bits[15] && (|bits[14:0] || bits[16]))};
      if ((rounded == 16'h0000) && bits[31])
        rounded = 16'h8000;
    end
    bf16_round_bits = {rounded, 16'h0000};
  end
endfunction

// Normalize a registered 14x14 BF22 significand product and perform the only
// RNE associated with this multiply.
function [21:0] bf22_pack_product;
  input sign_z;
  input zero_z;
  input special_z;
  input signed [11:0] exp_in;
  input [27:0] product;
  reg [13:0] main;
  reg guard_bit;
  reg sticky_bit;
  reg [14:0] rounded;
  reg signed [11:0] exp_z;
  reg signed [12:0] biased_exp;
  begin
    exp_z = exp_in;
    if (zero_z) begin
      bf22_pack_product = {sign_z, 21'b0};
    end else if (special_z) begin
      bf22_pack_product = {1'b0, 8'hff, 13'h1000};
    end else begin
      if (product[27]) begin
        main = product[27:14];
        guard_bit = product[13];
        sticky_bit = |product[12:0];
        exp_z = exp_z + 12'sd1;
      end else begin
        main = product[26:13];
        guard_bit = product[12];
        sticky_bit = |product[11:0];
      end
      rounded = {1'b0, main} +
                {14'b0, guard_bit && (sticky_bit || main[0])};
      if (rounded[14]) begin
        rounded = rounded >> 1;
        exp_z = exp_z + 12'sd1;
      end
      biased_exp = exp_z + 13'sd127;
      if ((product == 28'b0) || (exp_z < -12'sd126))
        bf22_pack_product = {sign_z, 21'b0};
      else if (biased_exp >= 13'sd255)
        bf22_pack_product = {sign_z, 8'hff, 13'b0};
      else
        bf22_pack_product = {sign_z, biased_exp[7:0], rounded[12:0]};
    end
  end
endfunction

// The first multiply consumes BF22 directly.  SOFTMAX_NORMALIZE selects the
// BF19 payload extended exactly into BF22; no operand-side rounding exists.
assign mul1_lhs_bf22 =
    (relay_mode_q == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
    {relay_payload_bf19_q, 3'b0} : relay_primary_bf22_q;
assign direct_bf22 = ((relay_mode_q == EDGE_ACTU_MODE_EXP_ONLY) ||
                      (relay_mode_q == EDGE_ACTU_MODE_SOFTMAX)) ?
                     relay_primary_bf22_q : relay_rcp_bf22_q;
assign mul1_sig_a = (mul1_lhs_bf22[20:13] == 8'b0) ?
                    {1'b0, mul1_lhs_bf22[12:0]} :
                    {1'b1, mul1_lhs_bf22[12:0]};
assign mul1_sig_b = (relay_rcp_bf22_q[20:13] == 8'b0) ?
                    {1'b0, relay_rcp_bf22_q[12:0]} :
                    {1'b1, relay_rcp_bf22_q[12:0]};
assign mul1_sign = mul1_lhs_bf22[21] ^ relay_rcp_bf22_q[21];
assign mul1_zero = (mul1_lhs_bf22[20:0] == 21'b0) ||
                   (relay_rcp_bf22_q[20:0] == 21'b0);
assign mul1_special = (mul1_lhs_bf22[20:13] == 8'hff) ||
                      (relay_rcp_bf22_q[20:13] == 8'hff);
assign mul1_exp =
    ((mul1_lhs_bf22[20:13] == 8'b0) ? -12'sd126 :
     ({4'b0, mul1_lhs_bf22[20:13]} - 12'sd127)) +
    ((relay_rcp_bf22_q[20:13] == 8'b0) ? -12'sd126 :
     ({4'b0, relay_rcp_bf22_q[20:13]} - 12'sd127));
// Preserve M1 as a physical leaf so full-ACTU APR can cluster this multiplier
// independently without changing its combinational boundary or product stage.
edge_actu_mul14_comb x_mul1 (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(mul1_sig_a),
  .rhs_sig_i(mul1_sig_b),
  .product_o(mul1_product)
);
assign mul1_product_bf22 = bf22_pack_product(
    mul1_sign_q, mul1_zero_q, mul1_special_q, mul1_exp_q, mul1_product_q);

// SiLU alone consumes the first BF22 product in a second 14x14 stage.  Its
// source payload originated at the BF16 memory boundary, so extending the
// compact BF19 packet adds zeros rather than another rounding operation.
assign mul3_lhs_bf22 = {mul2_payload_q, 3'b0};
assign mul3_sig_a = (mul3_lhs_bf22[20:13] == 8'b0) ?
                    {1'b0, mul3_lhs_bf22[12:0]} :
                    {1'b1, mul3_lhs_bf22[12:0]};
assign mul3_sig_b = (mul2_product_bf22_q[20:13] == 8'b0) ?
                    {1'b0, mul2_product_bf22_q[12:0]} :
                    {1'b1, mul2_product_bf22_q[12:0]};
assign mul3_sign = mul3_lhs_bf22[21] ^ mul2_product_bf22_q[21];
assign mul3_zero = (mul3_lhs_bf22[20:0] == 21'b0) ||
                   (mul2_product_bf22_q[20:0] == 21'b0);
assign mul3_special = (mul3_lhs_bf22[20:13] == 8'hff) ||
                      (mul2_product_bf22_q[20:13] == 8'hff);
assign mul3_exp =
    ((mul3_lhs_bf22[20:13] == 8'b0) ? -12'sd126 :
     ({4'b0, mul3_lhs_bf22[20:13]} - 12'sd127)) +
    ((mul2_product_bf22_q[20:13] == 8'b0) ? -12'sd126 :
     ({4'b0, mul2_product_bf22_q[20:13]} - 12'sd127));
edge_actu_mul14_comb x_mul3 (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(mul3_sig_a),
  .rhs_sig_i(mul3_sig_b),
  .product_o(mul3_product)
);
assign mul3_product_bf22 = bf22_pack_product(
    mul3_sign_q, mul3_zero_q, mul3_special_q, mul3_exp_q, mul3_product_q);

assign stage3_bypass_bf22 =
    (mul2_mode_q == EDGE_ACTU_MODE_SIGMOID) ? mul2_product_bf22_q :
    ((mul2_mode_q == EDGE_ACTU_MODE_TANH) ?
       {mul2_payload_q[18], mul2_product_bf22_q[20:0]} :
     ((mul2_mode_q == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
       mul2_product_bf22_q : mul2_direct_q));
assign final_result_bf22 = (final_mode_q == EDGE_ACTU_MODE_SILU) ?
                           mul3_product_bf22 : final_bypass_bf22_q;
assign final_result_bits = bf16_round_bits({final_result_bf22, 10'b0});

edge_actu_softmax_rsum x_softmax_rsum (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .clear_i(in_sum_clear),
  .in_valid_i(in_valid && (in_mode == EDGE_ACTU_MODE_SOFTMAX)),
  .in_last_i(in_last),
  .in_bf22_i(in_primary_bf22),
  .out_valid_o(softmax_sum_valid),
  .out_done_o(softmax_sum_done),
  .out_sum_bf22_o(softmax_sum_bf22)
);
assign softmax_sum_value = {softmax_sum_bf22, 10'b0};

always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    relay_valid_q <= 1'b0;
    relay_mode_q <= 3'b0;
    relay_payload_bf19_q <= 19'b0;
    relay_primary_bf22_q <= 22'b0;
    relay_rcp_bf22_q <= 22'b0;
    mul1_partial_mode_q <= 3'b0;
    mul1_partial_payload_q <= 19'b0;
    mul1_partial_direct_q <= 22'b0;
    mul1_partial_sign_q <= 1'b0;
    mul1_partial_zero_q <= 1'b0;
    mul1_partial_special_q <= 1'b0;
    mul1_partial_exp_q <= 12'sd0;
    mul1_mode_q <= 3'b0;
    mul1_payload_q <= 19'b0;
    mul1_direct_q <= 22'b0;
    mul1_sign_q <= 1'b0;
    mul1_zero_q <= 1'b0;
    mul1_special_q <= 1'b0;
    mul1_exp_q <= 12'sd0;
    mul1_product_q <= 28'b0;
    mul2_mode_q <= 3'b0;
    mul2_payload_q <= 19'b0;
    mul2_direct_q <= 22'b0;
    mul2_product_bf22_q <= 22'b0;
    mul3_partial_mode_q <= 3'b0;
    mul3_partial_bypass_bf22_q <= 22'b0;
    mul3_partial_sign_q <= 1'b0;
    mul3_partial_zero_q <= 1'b0;
    mul3_partial_special_q <= 1'b0;
    mul3_partial_exp_q <= 12'sd0;
    final_mode_q <= 3'b0;
    final_bypass_bf22_q <= 22'b0;
    mul3_sign_q <= 1'b0;
    mul3_zero_q <= 1'b0;
    mul3_special_q <= 1'b0;
    mul3_exp_q <= 12'sd0;
    mul3_product_q <= 28'b0;
    valid_pipe <= {POST_STAGES{1'b0}};
    for (stage = 0; stage < POST_STAGES; stage = stage + 1)
      mode_pipe[stage] <= 3'b0;
    for (stage = 0; stage <= OUTPUT_PIPE_LAST; stage = stage + 1)
      value_pipe[stage] <= 32'b0;
  end else begin
    // P0: pure packet relay at the backend/finalizer boundary.
    relay_valid_q <= in_valid;
    relay_mode_q <= in_mode;
    relay_payload_bf19_q <= in_payload_bf19;
    relay_primary_bf22_q <= in_primary_bf22;
    relay_rcp_bf22_q <= in_rcp_bf22;

    // M1P: each multiplier leaf registers two 14x7 partial products.
    mul1_partial_mode_q <= relay_mode_q;
    mul1_partial_payload_q <= relay_payload_bf19_q;
    mul1_partial_direct_q <= direct_bf22;
    mul1_partial_sign_q <= mul1_sign;
    mul1_partial_zero_q <= mul1_zero;
    mul1_partial_special_q <= mul1_special;
    mul1_partial_exp_q <= mul1_exp;

    // M1A: add the shifted partials and capture the exact 28-bit product.
    mul1_mode_q <= mul1_partial_mode_q;
    mul1_payload_q <= mul1_partial_payload_q;
    mul1_direct_q <= mul1_partial_direct_q;
    mul1_sign_q <= mul1_partial_sign_q;
    mul1_zero_q <= mul1_partial_zero_q;
    mul1_special_q <= mul1_partial_special_q;
    mul1_exp_q <= mul1_partial_exp_q;
    mul1_product_q <= mul1_product;

    // M2: normalize and round the first raw product once to BF22.
    mul2_mode_q <= mul1_mode_q;
    mul2_payload_q <= mul1_payload_q;
    mul2_direct_q <= mul1_direct_q;
    mul2_product_bf22_q <= mul1_product_bf22;

    // M3P: second pair of 14x7 partials for SiLU; other modes relay.
    mul3_partial_mode_q <= mul2_mode_q;
    mul3_partial_bypass_bf22_q <= stage3_bypass_bf22;
    mul3_partial_sign_q <= mul3_sign;
    mul3_partial_zero_q <= mul3_zero;
    mul3_partial_special_q <= mul3_special;
    mul3_partial_exp_q <= mul3_exp;

    // M3A: shifted partial add and exact-product capture.
    final_mode_q <= mul3_partial_mode_q;
    final_bypass_bf22_q <= mul3_partial_bypass_bf22_q;
    mul3_sign_q <= mul3_partial_sign_q;
    mul3_zero_q <= mul3_partial_zero_q;
    mul3_special_q <= mul3_partial_special_q;
    mul3_exp_q <= mul3_partial_exp_q;
    mul3_product_q <= mul3_product;

    // Output: second-product pack (SiLU) or bypass, then BF16 store round.
    value_pipe[0] <= final_result_bits;
    for (stage = 1; stage <= OUTPUT_PIPE_LAST; stage = stage + 1)
      value_pipe[stage] <= value_pipe[stage - 1];

    valid_pipe[0] <= relay_valid_q;
    mode_pipe[0] <= relay_mode_q;
    for (stage = 1; stage < POST_STAGES; stage = stage + 1) begin
      valid_pipe[stage] <= valid_pipe[stage - 1];
      mode_pipe[stage] <= mode_pipe[stage - 1];
    end
  end
end

endmodule
