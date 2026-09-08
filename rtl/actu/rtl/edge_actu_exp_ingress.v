`timescale 1ns/1ps

// Seven captures: decode+coarse/fine+add/normalize/RNE+Q12/multiply/range+LUT/multiply.
// Every mode and sideband takes the same path; scalar epsilon is BF16, while the retained sum is BF22.
module edge_actu_exp_ingress #(parameter PRE_ROUNDED_EXP=0) (
  input wire clk, cpurst_b, in_valid, in_last, in_sum_clear,
  input wire [2:0] in_mode,
  input wire [15:0] in_value_bf16,
  input wire [31:0] in_scalar_bits,
  output reg out_valid, out_last, out_sum_clear,
  output reg [2:0] out_mode,
  output reg [15:0] out_value_bf16,
  output reg [21:0] out_scalar_bf22,
  output reg out_underflow,
  output reg signed [9:0] out_exp2_k,
  output reg [20:0] out_residual_product,
  output reg [14:0] out_hi,
  output reg [5:0] out_residual,
  output reg [11:0] out_frac_code,
  output reg out_overflow, out_clamped,
  output reg [14:0] out_rounded_mant
);
wire [15:0] delta_candidate;
reg [18:0] magnitude_q;
reg prepared_sign_q, prepared_underflow_q;
wire delta_overflow;
reg prepared_overflow_q, overflow_q, prepared_clamp_q, clamp_q;
reg [21:0] native_operand_q [0:2];
reg [2:0] scale_overflow_q;
wire [8:0] scale_exponent={1'b0,in_value_bf16[14:7]}+9'd1;
reg [15:0] range_low_q;
reg [23:0] range_high_q;
reg sign_q, underflow_q;
reg [5:0] valid_q;
reg [2:0] mode_q [0:5];
reg [15:0] value_q [0:5];
reg [21:0] scalar_q [0:5];
reg [5:0] last_q, clear_q;
integer stage;
function [21:0] native_exp_operand;
  input [15:0] value;
  input [2:0] mode;
  reg [15:0] scaled;
  reg [7:0] doubled_exponent;
  begin
    scaled={1'b1,value[14:0]};
    doubled_exponent=value[14:7]+8'd1;
    // Multiply magnitude by two; subnormal significands shift normally.
    // Extended-exponent overflow travels separately, never materialized as Inf.
    if (mode==3'd4)
      scaled=value[14:7]==0 ? {1'b1,7'b0,value[6:0],1'b0} :
                             {1'b1,doubled_exponent,value[6:0]};
    if (mode==3'd2 || mode==3'd3 || mode==3'd4) native_exp_operand={scaled,6'b0};
    else native_exp_operand={value,6'b0};
  end
endfunction
// G1 aligns and adds; G2 normalizes; G3 rounds and prepares Q12.
edge_actu_softmax_sub_bf16_pipe x_subtract (
  .clk(clk),.cpurst_b(cpurst_b),.in_valid(in_valid),
  .value_bf16(in_value_bf16),.max_bf16(in_scalar_bits[31:16]),
  .out_valid(),.delta_bf16(),.delta_before_capture(),
  .overflow_before_capture(delta_overflow),.candidate_before_capture(delta_candidate)
);
wire range_underflow, range_sign, range_clamp;
wire [18:0] range_magnitude;
wire signed [9:0] range_k;
wire [11:0] range_frac;
// G3 selects/prepares Q12. G4 computes constant partial products.
edge_actu_exp_range_bf22_prepare_numeric #(.FREE_RUN(1)) x_range_prepare (
  .value_bf22(mode_q[2]==3'd5 ? {delta_candidate,6'b0} : native_operand_q[2]),
  .underflow(range_underflow),.sign_z(range_sign),.magnitude_q12(range_magnitude),.clamp_high(range_clamp)
);
// 23637 = 85 + (23 << 10). Low ten product bits cannot carry into bit ten.
wire [25:0] range_low=magnitude_q*7'd85;
wire [23:0] range_high=magnitude_q*5'd23;
// G5 combines truncated partial products and applies the separate numeric sign.
edge_actu_exp_range_bf22_scale_parts x_range_scale (
  .negative_nonzero(sign_q),.low_q(range_low_q),.high_q(range_high_q),
  .exp2_k(range_k),.frac_code(range_frac)
);
wire [14:0] range_hi;
wire [5:0] range_residual;
// G5 captures LUT results. G6 multiplies them with no range/LUT logic in series.
reg [14:0] hi_q;
reg [5:0] residual_q;
reg signed [9:0] k_q;
reg [11:0] frac_q;
reg underflow_lut_q,overflow_lut_q,clamp_lut_q;
edge_actu_exp_lut_pair x_lut(range_frac,range_hi,range_residual);
wire [20:0] residual_product=hi_q*residual_q;
wire [28:0] mantissa_q28={hi_q,14'b0}+{8'b0,residual_product};
wire round_increment=mantissa_q28[14] && (|mantissa_q28[13:0] || mantissa_q28[15]);
always @(posedge clk) begin
  out_rounded_mant<=PRE_ROUNDED_EXP ? ({1'b0,mantissa_q28[28:15]}+{14'b0,round_increment}) : 15'b0;
  hi_q<=range_hi;residual_q<=range_residual;k_q<=range_k;frac_q<=range_frac;
  underflow_lut_q<=underflow_q;overflow_lut_q<=overflow_q;clamp_lut_q<=clamp_q;
  out_hi<=PRE_ROUNDED_EXP ? 15'b0 : hi_q;out_residual<=residual_q;
  out_residual_product<=PRE_ROUNDED_EXP ? 21'b0 : residual_product;
  native_operand_q[0]<=native_exp_operand(in_value_bf16,in_mode);
  scale_overflow_q<={scale_overflow_q[1:0],in_mode==3'd4 && scale_exponent>=9'd255};
  for(stage=1;stage<3;stage=stage+1)native_operand_q[stage]<=native_operand_q[stage-1];
  range_low_q<=range_low[25:10]; range_high_q<=range_high; sign_q<=prepared_sign_q; underflow_q<=prepared_underflow_q;
  // Overflow is produced by subtraction/RNE, never predicted from input class.
  prepared_overflow_q<=mode_q[2]==3'd5 && delta_overflow && !delta_candidate[15];
  overflow_q<=prepared_overflow_q;
  prepared_clamp_q<=range_clamp;clamp_q<=prepared_clamp_q;out_clamped<=clamp_lut_q;
  magnitude_q<=range_magnitude;prepared_sign_q<=range_sign && (|range_magnitude);prepared_underflow_q<=range_underflow ||
    (mode_q[2]==3'd5 && delta_overflow && delta_candidate[15]) || scale_overflow_q[2];
  mode_q[0]<=in_mode;
  value_q[0]<=in_value_bf16;
  // Only normalize carries an internal BF22 sum. External max/epsilon are BF16.
  scalar_q[0]<=(in_mode==3'd7) ? in_scalar_bits[31:10] : {in_scalar_bits[31:16],6'b0};
  for(stage=1;stage<6;stage=stage+1)begin
    mode_q[stage]<=mode_q[stage-1];value_q[stage]<=value_q[stage-1];scalar_q[stage]<=scalar_q[stage-1];
  end
  out_mode<=mode_q[5]; out_value_bf16<=value_q[5];
  out_scalar_bf22<=scalar_q[5];
  out_underflow<=underflow_lut_q; out_exp2_k<=k_q; out_overflow<=overflow_lut_q; out_frac_code<=frac_q;
end
always @(posedge clk or negedge cpurst_b)
  if (!cpurst_b) begin
    out_valid<=1'b0; valid_q<=0; last_q<=0; clear_q<=0; out_last<=0; out_sum_clear<=0;
  end else begin
    valid_q<={valid_q[4:0],in_valid};
    out_valid<=valid_q[5];
    last_q<={last_q[4:0],in_last}; clear_q<={clear_q[4:0],in_sum_clear};
    out_last<=last_q[5]; out_sum_clear<=clear_q[5];
  end
endmodule
