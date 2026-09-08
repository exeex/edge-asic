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

function [2:0] classify;
 input [21:0] b;
 begin
  classify=(b[20:13]==0) ? ((|b[12:0])?3'd2:3'd1) :
           (&b[20:13]) ? ((|b[12:0])?3'd5:3'd4) : 3'd0;
 end
endfunction
edge_actu_finalizer_classified #(.POST_STAGES(POST_STAGES)) core (
 .clk(clk),.cpurst_b(cpurst_b),.in_valid(in_valid),.in_last(in_last),
 .in_mode(in_mode),.in_payload_bf19(in_payload_bf19),
 .in_primary_bf22(in_primary_bf22),.in_rcp_bf22(in_rcp_bf22),
 .in_result_action(4'd0),
 .in_payload_class(classify({in_payload_bf19,3'b0})),
 .in_primary_class(classify(in_primary_bf22)),.in_rcp_class(classify(in_rcp_bf22)),
 .in_primary_operand(22'b0),.in_payload_operand(22'b0),.in_rcp_operand(22'b0),
 .in_sum_clear(in_sum_clear),.out_valid(out_valid),.out_mode(out_mode),
 .out_value(out_value),.softmax_sum_valid(softmax_sum_valid),
 .softmax_sum_done(softmax_sum_done),.softmax_sum_value(softmax_sum_value)
);
endmodule

`timescale 1ns/1ps

// Output-side ACTU finalizer.  The RCP backend hands this block one compact,
// latency-aligned packet; this block owns all post-RCP arithmetic, result
// selection, softmax accumulation, and output pipeline state.
(* keep_hierarchy = "yes" *)
module edge_actu_finalizer_classified #(
  parameter INPUT_POLICY = 0,
  parameter FINITE_INPUTS = 0,
  parameter EXTERNAL_RSUM = 0,
  parameter PREPARED_INPUTS = 0,
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
  input  wire [3:0]  in_result_action,
  input  wire [2:0]  in_primary_class, in_payload_class, in_rcp_class,
  input wire [21:0] in_primary_operand, in_payload_operand, in_rcp_operand,
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

// P0: select and capture the prepared M1 operand; relay other packet fields.
// M1 consumes only these registered fields; capture count and II are unchanged.
reg               relay_valid_q;
reg [2:0]         relay_mode_q;
reg [18:0]        relay_payload_bf19_q;
reg [21:0]        relay_primary_bf22_q;
reg [21:0]        relay_rcp_bf22_q;

// M1P: metadata aligned with the registered pair of 14x7 partial products.
wire [2:0] mul1_partial_mode_q = mode_pipe[0];
reg [18:0]        mul1_partial_payload_q;
reg [21:0]        mul1_partial_direct_q;
reg               mul1_partial_sign_q;
reg               mul1_partial_zero_q;
reg               mul1_partial_special_q;
reg signed [11:0] mul1_partial_exp_q;

// M1A: registered raw BF22 numerator/reciprocal product after partial add.
wire [2:0] mul1_mode_q = mode_pipe[1];
reg [18:0]        mul1_payload_q;
reg [21:0]        mul1_direct_q;
reg               mul1_sign_q;
reg               mul1_zero_q;
reg               mul1_special_q;
reg signed [11:0] mul1_exp_q;
reg [27:0]        mul1_product_q;

// M2: first product rounded once to BF22.
wire [2:0] mul2_mode_q = mode_pipe[2];
reg [18:0] mul2_payload_q;
reg [21:0] mul2_direct_q;
reg [21:0] mul2_product_bf22_q;

// M3P: metadata/bypass aligned with SiLU's second 14x7 partial pair.
wire [2:0] mul3_partial_mode_q = mode_pipe[3];
reg [21:0]        mul3_partial_bypass_bf22_q;
reg               mul3_partial_sign_q;
reg               mul3_partial_zero_q;
reg               mul3_partial_special_q;
reg signed [11:0] mul3_partial_exp_q;

// M3A: SiLU's second raw BF22 product or a mode-aligned bypass result.
wire [2:0] final_mode_q = mode_pipe[4];
reg [21:0]        final_bypass_bf22_q;
reg               mul3_sign_q;
reg               mul3_zero_q;
reg               mul3_special_q;
reg signed [11:0] mul3_exp_q;
reg [27:0]        mul3_product_q;

// Class is resetless packet data; sign remains in the numerical payload.
reg [2:0] relay_primary_class, relay_payload_class, relay_rcp_class;
reg [2:0] partial_payload_class, partial_direct_class;
reg [2:0] mul1_payload_class, mul1_direct_class;
reg [2:0] mul2_payload_class, mul2_direct_class, mul2_product_class;
reg [2:0] partial_bypass_class, final_bypass_class;
wire [2:0] lhs1_class = (relay_mode_q==EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
                      relay_payload_class : relay_primary_class;
wire [2:0] direct_class = ((relay_mode_q==EDGE_ACTU_MODE_EXP_ONLY) ||
                         (relay_mode_q==EDGE_ACTU_MODE_SOFTMAX)) ?
                         relay_primary_class : relay_rcp_class;
wire [2:0] bypass_class = ((mul2_mode_q==EDGE_ACTU_MODE_SIGMOID) ||
                         (mul2_mode_q==EDGE_ACTU_MODE_TANH) ||
                         (mul2_mode_q==EDGE_ACTU_MODE_SOFTMAX_NORMALIZE)) ?
                         mul2_product_class : mul2_direct_class;
wire [24:0] packed1, packed3;
wire [2:0] final_class = (final_mode_q==EDGE_ACTU_MODE_SILU) ?
                       packed3[24:22] : final_bypass_class;
function special_class;
 input [2:0] c;
 begin special_class=(c==3'd4)||(c==3'd5); end
endfunction
always @(posedge clk) begin
 relay_primary_class<=in_primary_class;relay_payload_class<=in_payload_class;
 relay_rcp_class<=in_rcp_class;
 partial_payload_class<=relay_payload_class;partial_direct_class<=direct_class;
 mul1_payload_class<=partial_payload_class;mul1_direct_class<=partial_direct_class;
 mul2_payload_class<=mul1_payload_class;mul2_direct_class<=mul1_direct_class;
 mul2_product_class<=packed1[24:22];
 partial_bypass_class<=bypass_class;final_bypass_class<=partial_bypass_class;
end

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

function [15:0] bf22_to_bf16;
  input [21:0] bits;
  begin
    bf22_to_bf16 = bits[21:6] +
                    {15'b0, (bits[5] && (|bits[4:0] || bits[6]))};
  end
endfunction

// Pure numeric rounding. Status is observed in parallel; it never selects
// or overwrites the rounded candidate fed into the next multiplier.
function [23:0] round_product;
 input signed [11:0] exp_in;
 input [27:0] product;
 reg [13:0] main;
 reg guard_bit,sticky_bit;
 reg [14:0] rounded;
 reg signed [11:0] exp_z;
 reg signed [12:0] biased_exp;
 begin
  exp_z=exp_in;
  if(product[27])begin
   main=product[27:14];guard_bit=product[13];sticky_bit=|product[12:0];
   exp_z=exp_z+12'sd1;
  end else begin
   main=product[26:13];guard_bit=product[12];sticky_bit=|product[11:0];
  end
  rounded={1'b0,main}+{14'b0,guard_bit&&(sticky_bit||main[0])};
  if(rounded[14])begin rounded=rounded>>1;exp_z=exp_z+12'sd1;end
  biased_exp=exp_z+13'sd127;
  round_product={(product==0)||(exp_z < -12'sd126),
                 biased_exp>=13'sd255,biased_exp[7:0],rounded[13:0]};
 end
endfunction
function [2:0] product_class;
 input zero_z,special_z,underflow,overflow;
 begin
  product_class=zero_z ? 3'd1 : special_z ? 3'd5 :
                underflow ? 3'd1 : overflow ? 3'd4 : 3'd0;
 end
endfunction
// Prepared operand is {effective biased exponent, hidden bit, fraction}.
function [21:0] prepare_operand;
 input [21:0] b;
 begin prepare_operand={b[20:13]==0?8'd1:b[20:13],(b[20:13]!=0),b[12:0]};end
endfunction
reg [21:0] relay_primary_operand,relay_payload_operand,relay_rcp_operand;
reg [21:0] partial_payload_operand,mul1_payload_operand,mul2_payload_operand;
wire [21:0] lhs1_operand=relay_primary_operand;
wire [23:0] rounded1=round_product(mul1_exp_q,mul1_product_q);
wire [23:0] rounded3=round_product(mul3_exp_q,mul3_product_q);
wire semantic_sign1=(!mul1_zero_q && mul1_special_q)?1'b0:mul1_sign_q;
wire semantic_sign3=(!mul3_zero_q && mul3_special_q)?1'b0:mul3_sign_q;
always @(posedge clk)begin
 relay_primary_operand <= (in_mode==EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
   (PREPARED_INPUTS?in_payload_operand:prepare_operand({in_payload_bf19,3'b0})) :
   (PREPARED_INPUTS?in_primary_operand:prepare_operand(in_primary_bf22));
 relay_payload_operand<=PREPARED_INPUTS?in_payload_operand:prepare_operand({in_payload_bf19,3'b0});
 relay_rcp_operand<=PREPARED_INPUTS?in_rcp_operand:prepare_operand(in_rcp_bf22);
 partial_payload_operand<=relay_payload_operand;
 mul1_payload_operand<=partial_payload_operand;
 mul2_payload_operand<=mul1_payload_operand;
end

// The first multiply consumes BF22 directly.  SOFTMAX_NORMALIZE selects the
// BF19 payload extended exactly into BF22; no operand-side rounding exists.
assign mul1_lhs_bf22 =
    (relay_mode_q == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
    {relay_payload_bf19_q, 3'b0} : relay_primary_bf22_q;
assign direct_bf22 = ((relay_mode_q == EDGE_ACTU_MODE_EXP_ONLY) ||
                      (relay_mode_q == EDGE_ACTU_MODE_SOFTMAX)) ?
                     relay_primary_bf22_q : relay_rcp_bf22_q;
assign mul1_sig_a=lhs1_operand[13:0];
assign mul1_sig_b=relay_rcp_operand[13:0];
assign mul1_sign = mul1_lhs_bf22[21] ^ relay_rcp_bf22_q[21];
assign mul1_zero = (lhs1_class == 3'd1) ||
                   (relay_rcp_class == 3'd1);
assign mul1_special = !FINITE_INPUTS && (special_class(lhs1_class) ||
                      special_class(relay_rcp_class));
assign mul1_exp=$signed({4'b0,lhs1_operand[21:14]})+
                $signed({4'b0,relay_rcp_operand[21:14]})-12'sd254;
// Preserve M1 as a physical leaf so full-ACTU APR can cluster this multiplier
// independently without changing its combinational boundary or product stage.
edge_actu_mul14_comb #(.RESET_DATA(0)) x_mul1 (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(mul1_sig_a),
  .rhs_sig_i(mul1_sig_b),
  .product_o(mul1_product)
);
assign mul1_product_bf22 = packed1[21:0];
assign packed1={product_class(mul1_zero_q,mul1_special_q,rounded1[23],rounded1[22]),
                semantic_sign1,rounded1[21:14],rounded1[12:0]};

// SiLU alone consumes the first BF22 product in a second 14x14 stage.  Its
// source payload originated at the BF16 memory boundary, so extending the
// compact BF19 packet adds zeros rather than another rounding operation.
assign mul3_lhs_bf22 = {mul2_payload_q, 3'b0};
assign mul3_sig_a=mul2_payload_operand[13:0];
// A finite nonzero M2 result uses the legacy normal hidden bit. Exceptional
// candidates are don't-care arithmetic; only the parallel semantic state matters.
assign mul3_sig_b={1'b1,mul2_product_bf22_q[12:0]};
assign mul3_sign = mul3_lhs_bf22[21] ^ mul2_product_bf22_q[21];
assign mul3_zero = (mul2_payload_class == 3'd1) ||
                   (mul2_product_class == 3'd1);
assign mul3_special = !FINITE_INPUTS && (special_class(mul2_payload_class) ||
                      special_class(mul2_product_class));
assign mul3_exp=$signed({4'b0,mul2_payload_operand[21:14]})+
                $signed({4'b0,mul2_product_bf22_q[20:13]})-12'sd254;
edge_actu_mul14_comb #(.RESET_DATA(0)) x_mul3 (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .lhs_sig_i(mul3_sig_a),
  .rhs_sig_i(mul3_sig_b),
  .product_o(mul3_product)
);
assign mul3_product_bf22 = packed3[21:0];
assign packed3={product_class(mul3_zero_q,mul3_special_q,rounded3[23],rounded3[22]),
                semantic_sign3,rounded3[21:14],rounded3[12:0]};

// SiLU does not consume this bypass numerically. Reuse it for its input rail.
assign stage3_bypass_bf22 =
    (mul2_mode_q == EDGE_ACTU_MODE_SILU) ? {mul2_payload_q,3'b0} :
    (mul2_mode_q == EDGE_ACTU_MODE_SIGMOID) ? mul2_product_bf22_q :
    ((mul2_mode_q == EDGE_ACTU_MODE_TANH) ?
       {mul2_payload_q[18], mul2_product_bf22_q[20:0]} :
     ((mul2_mode_q == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE) ?
       mul2_product_bf22_q : mul2_direct_q));
assign final_result_bf22 = (final_mode_q == EDGE_ACTU_MODE_SILU) ?
                           mul3_product_bf22 : final_bypass_bf22_q;
wire [15:0] finite_result=bf22_to_bf16(final_result_bf22);
// Entry semantics are resolved before the existing output capture, not after it.
reg [3:0] result_action_q[0:5];
reg [5:0] rcp_zero_q;
reg action_sign_p, action_sign_q;
integer result_action_stage;
always @(posedge clk)begin
 rcp_zero_q<={rcp_zero_q[4:0],in_rcp_class==3'd1};
 result_action_q[0]<=in_result_action;
 for(result_action_stage=1;result_action_stage<6;result_action_stage=result_action_stage+1)
  result_action_q[result_action_stage]<=result_action_q[result_action_stage-1];
end
function [15:0] action_bits;
 input [3:0] action;
 begin
  case(action)
   1:action_bits=16'h0000; 2:action_bits=16'h8000;
   3:action_bits=16'h3f80; 4:action_bits=16'hbf80;
   5:action_bits=16'h7f80; 6:action_bits=16'hff80;
   8:action_bits=final_bypass_bf22_q[21:6];
   9:action_bits=16'h1f80; // RSQRT of the established maximum-finite saturation.
   10:action_bits=16'h7ef8; // Established EXP(+88) finite clamp.
   default:action_bits=16'h7fc0;
  endcase
 end
endfunction
// Merge entry/generated policy with numerical result status first. A single
// output selection materializes the semantic result; it never feeds arithmetic.
wire zero_sign=INPUT_POLICY && (final_mode_q==3'd1 || final_mode_q==3'd6) ? 1'b0 :
               INPUT_POLICY && final_mode_q==3'd7 && rcp_zero_q[5] ? action_sign_q : final_result_bf22[21];
wire [3:0] numeric_action=final_class==3'd1 ? (zero_sign?4'd2:4'd1) :
                          final_class==3'd4 ? (final_result_bf22[21]?4'd6:4'd5) :
                          final_class==3'd5 ? 4'd7 : 4'd0;
wire [3:0] merged_action=INPUT_POLICY && result_action_q[5]!=0 ?
                         result_action_q[5] : numeric_action;
assign final_result_bits={merged_action==0 ? finite_result : action_bits(merged_action),16'b0};

generate if(!EXTERNAL_RSUM)begin: internal_rsum
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
end else begin: external_rsum
 assign softmax_sum_valid=0;assign softmax_sum_done=0;assign softmax_sum_bf22=0;
end endgenerate
assign softmax_sum_value = {softmax_sum_bf22, 10'b0};

// Reset cancels valid immediately. Mode travels with unreset data and is
// unspecified when invalid; the reducer retains its independent state reset.
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    relay_valid_q <= 1'b0;

    valid_pipe <= {POST_STAGES{1'b0}};
  end else begin
    relay_valid_q <= in_valid;

    valid_pipe[0] <= relay_valid_q;
    for (stage = 1; stage < POST_STAGES; stage = stage + 1) begin
      valid_pipe[stage] <= valid_pipe[stage - 1];
    end
  end
end

integer data_stage;
always @(posedge clk) begin
    relay_mode_q <= in_mode;
    mode_pipe[0] <= relay_mode_q;
    for (data_stage = 1; data_stage < POST_STAGES; data_stage = data_stage + 1)
      mode_pipe[data_stage] <= mode_pipe[data_stage - 1];

    // P0: packet relay; prepared M1 operand is selected in its capture block above.
    relay_payload_bf19_q <= in_payload_bf19;
    relay_primary_bf22_q <= in_primary_bf22;
    relay_rcp_bf22_q <= in_rcp_bf22;

    // M1P: each multiplier leaf registers two 14x7 partial products.
    mul1_partial_payload_q <= relay_payload_bf19_q;
    mul1_partial_direct_q <= direct_bf22;
    mul1_partial_sign_q <= mul1_sign;
    mul1_partial_zero_q <= mul1_zero;
    mul1_partial_special_q <= mul1_special;
    mul1_partial_exp_q <= mul1_exp;

    // M1A: add the shifted partials and capture the exact 28-bit product.
    mul1_payload_q <= mul1_partial_payload_q;
    mul1_direct_q <= mul1_partial_direct_q;
    mul1_sign_q <= mul1_partial_sign_q;
    mul1_zero_q <= mul1_partial_zero_q;
    mul1_special_q <= mul1_partial_special_q;
    mul1_exp_q <= mul1_partial_exp_q;
    mul1_product_q <= mul1_product;

    // M2: normalize and round the first raw product once to BF22.
    mul2_payload_q <= mul1_payload_q;
    mul2_direct_q <= mul1_direct_q;
    mul2_product_bf22_q <= mul1_product_bf22;

    // M3P: second pair of 14x7 partials for SiLU; other modes relay.
    action_sign_p<=mul2_payload_q[18];
    action_sign_q<=action_sign_p;
    mul3_partial_bypass_bf22_q <= stage3_bypass_bf22;
    mul3_partial_sign_q <= mul3_sign;
    mul3_partial_zero_q <= mul3_zero;
    mul3_partial_special_q <= mul3_special;
    mul3_partial_exp_q <= mul3_exp;

    // M3A: shifted partial add and exact-product capture.
    final_bypass_bf22_q <= mul3_partial_bypass_bf22_q;
    mul3_sign_q <= mul3_partial_sign_q;
    mul3_zero_q <= mul3_partial_zero_q;
    mul3_special_q <= mul3_partial_special_q;
    mul3_exp_q <= mul3_partial_exp_q;
    mul3_product_q <= mul3_product;

    // Output: second-product pack (SiLU) or bypass, then BF16 store round.
    value_pipe[0] <= final_result_bits;
    for (data_stage = 1; data_stage <= OUTPUT_PIPE_LAST; data_stage = data_stage + 1)
      value_pipe[data_stage] <= value_pipe[data_stage - 1];

end

`ifndef SYNTHESIS
function [2:0] observed_class;
 input [21:0] b;
 begin
  case(b[20:13])
   0:observed_class=(b[12:0]==0)?3'd1:3'd2;
   255:observed_class=(b[12:0]==0)?3'd4:3'd5;
   default:observed_class=3'd0;
  endcase
 end
endfunction
always @(posedge clk) if(cpurst_b) begin
 if(in_valid && PREPARED_INPUTS &&
    ({in_primary_operand,in_payload_operand,in_rcp_operand} !==
     {prepare_operand(in_primary_bf22),
      prepare_operand({in_payload_bf19,3'b0}),
      prepare_operand(in_rcp_bf22)}))
  $fatal(1,"finalizer prepared operand alignment mismatch");
 // Primary ZERO/INF and reciprocal ZERO can carry arbitrary candidates. Standalone
 // raw callers remain checked exactly; integrated prepared callers use class.
 if(in_valid && (({in_primary_class,in_payload_class} !==
   {(PREPARED_INPUTS && (in_primary_class==3'd1 || in_primary_class==3'd3 || in_primary_class==3'd4) ? in_primary_class : observed_class(in_primary_bf22)),(INPUT_POLICY ? (in_payload_bf19[17:0]==0 ? 3'd1 : 3'd0) : (FINITE_INPUTS && in_payload_bf19[17:10]==255 ? 3'd0 : observed_class({in_payload_bf19,3'b0})))}) ||
   ((!PREPARED_INPUTS || in_rcp_class!=3'd1) &&
    in_rcp_class !== observed_class(in_rcp_bf22))))
  $fatal(1,"finalizer input class mismatch");
 if(!FINITE_INPUTS && valid_pipe[2] && mul2_product_class==0 && observed_class(mul2_product_bf22_q)!=0)
  $fatal(1,"finalizer M2 class mismatch");
 if(!FINITE_INPUTS && valid_pipe[4] && final_class==0 && observed_class(final_result_bf22)!=0)
  $fatal(1,"finalizer output pack class mismatch");
end
`endif

endmodule
