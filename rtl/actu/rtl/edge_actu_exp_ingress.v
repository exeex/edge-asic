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
// G5 banked LUT: exact constants from edge_actu_exp_lut_pair.
assign range_residual[0]=(16'h5ad2 >> range_frac[3:0]) & 1'b1;
assign range_residual[1]=(16'hc9b6 >> range_frac[3:0]) & 1'b1;
assign range_residual[2]=(16'h6d24 >> range_frac[3:0]) & 1'b1;
assign range_residual[3]=(16'h8e38 >> range_frac[3:0]) & 1'b1;
assign range_residual[4]=(16'h0fc0 >> range_frac[3:0]) & 1'b1;
assign range_residual[5]=(16'hf000 >> range_frac[3:0]) & 1'b1;
// Sixteen high-address banks use four-bit local truth tables.
wire [15:0] lut_bank_decode=16'b1 << range_frac[11:8];
wire [14:0] lut_bank [0:15];
assign lut_bank[0][0]=(16'hf9a4 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][1]=(16'had38 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][2]=(16'h9b6a >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][3]=(16'h78e6 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][4]=(16'h52b4 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][5]=(16'hc992 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][6]=(16'h6d24 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][7]=(16'h8e38 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][8]=(16'h0fc0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][9]=(16'hf000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][10]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][11]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[0][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][0]=(16'h8ea9 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][1]=(16'hfe64 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][2]=(16'h01e3 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][3]=(16'hffe0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][4]=(16'haab5 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][5]=(16'h666c >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][6]=(16'h4b49 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][7]=(16'h8c71 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][8]=(16'hf07e >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][9]=(16'h007f >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][10]=(16'hff80 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][11]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[1][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][0]=(16'hfc9b >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][1]=(16'ha923 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][2]=(16'hce3c >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][3]=(16'hf03f >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][4]=(16'h556a >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][5]=(16'hcce6 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][6]=(16'h694b >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][7]=(16'h8e73 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][8]=(16'h0f83 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][9]=(16'h0ffc >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][10]=(16'h0fff >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][11]=(16'hf000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[2][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][0]=(16'hc0d4 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][1]=(16'hffcd >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][2]=(16'haa96 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][3]=(16'h3318 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][4]=(16'h694a >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][5]=(16'he739 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][6]=(16'hb5ad >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][7]=(16'hc631 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][8]=(16'hf83e >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][9]=(16'hffc0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][10]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][11]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[3][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][0]=(16'h5fca >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][1]=(16'h356c >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][2]=(16'hf325 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][3]=(16'h5a49 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][4]=(16'h36db >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][5]=(16'h0e38 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][6]=(16'hab52 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][7]=(16'h339c >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][8]=(16'hc3e0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][9]=(16'hfc00 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][10]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][11]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[4][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][0]=(16'h560d >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][1]=(16'h9803 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][2]=(16'he000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][3]=(16'h5555 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][4]=(16'h3333 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][5]=(16'h0f0f >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][6]=(16'haa55 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][7]=(16'hcc66 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][8]=(16'h0f87 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][9]=(16'hf007 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][10]=(16'h0007 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][11]=(16'h0007 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][12]=(16'hfff8 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[5][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][0]=(16'h357f >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][1]=(16'h0cd5 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][2]=(16'h5699 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][3]=(16'h324b >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][4]=(16'hf1c7 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][5]=(16'hf03f >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][6]=(16'ha555 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][7]=(16'h3999 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][8]=(16'h3e1e >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][9]=(16'hc01f >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][10]=(16'hffe0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][11]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][12]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[6][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][0]=(16'h7eac >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][1]=(16'h2b30 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][2]=(16'he695 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][3]=(16'h1e73 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][4]=(16'h01f0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][5]=(16'h000f >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][6]=(16'haaaa >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][7]=(16'h3333 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][8]=(16'h3c3c >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][9]=(16'hc03f >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][10]=(16'h003f >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][11]=(16'hffc0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][12]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[7][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][0]=(16'ha81a >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][1]=(16'hcff9 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][2]=(16'h0ff8 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][3]=(16'h0ff8 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][4]=(16'h0ff8 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][5]=(16'h0ff8 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][6]=(16'ha552 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][7]=(16'h3663 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][8]=(16'h387c >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][9]=(16'hc07f >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][10]=(16'hff80 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][11]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][12]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][13]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[8][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][0]=(16'hf2c0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][1]=(16'hf1aa >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][2]=(16'ha533 >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][3]=(16'hc63c >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][4]=(16'h07c0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][5]=(16'hf800 >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][6]=(16'haaaa >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][7]=(16'h3333 >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][8]=(16'h3c3c >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][9]=(16'hc03f >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][10]=(16'h003f >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][11]=(16'h003f >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][12]=(16'h003f >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][13]=(16'hffc0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[9][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][0]=(16'hafd4 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][1]=(16'h9a98 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][2]=(16'h79b5 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][3]=(16'had26 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][4]=(16'h31c7 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][5]=(16'h3e07 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][6]=(16'h9552 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][7]=(16'hd99b >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][8]=(16'h1e1c >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][9]=(16'he01f >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][10]=(16'hffe0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][11]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][13]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[10][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][0]=(16'h0288 >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][1]=(16'h54f7 >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][2]=(16'h6700 >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][3]=(16'hd2aa >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][4]=(16'h9b33 >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][5]=(16'h1c3c >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][6]=(16'hb56a >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][7]=(16'h264c >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][8]=(16'hc78f >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][9]=(16'hf80f >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][10]=(16'h000f >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][11]=(16'hfff0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][12]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][13]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[11][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][0]=(16'hc41a >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][1]=(16'h67f9 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][2]=(16'h2d52 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][3]=(16'he336 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][4]=(16'hb5a4 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][5]=(16'h39c7 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][6]=(16'h6b52 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][7]=(16'h4d9b >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][8]=(16'h71e3 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][9]=(16'h7e03 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][10]=(16'h7ffc >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][11]=(16'h7fff >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][12]=(16'h8000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][13]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[12][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][0]=(16'hb1ac >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][1]=(16'hc065 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][2]=(16'hffe3 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][3]=(16'hffe0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][4]=(16'h554a >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][5]=(16'h6673 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][6]=(16'h2d29 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][7]=(16'h49b2 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][8]=(16'h8e3c >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][9]=(16'h0fc0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][10]=(16'hf000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][11]=(16'h0000 >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][12]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][13]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[13][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][0]=(16'h7cc8 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][1]=(16'h83a2 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][2]=(16'haacc >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][3]=(16'hccf0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][4]=(16'ha5aa >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][5]=(16'hc933 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][6]=(16'h5b69 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][7]=(16'h6db2 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][8]=(16'h71c3 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][9]=(16'h81fc >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][10]=(16'h01ff >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][11]=(16'hfe00 >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][12]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][13]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[14][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][0]=(16'hfacd >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][1]=(16'hf9a9 >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][2]=(16'hf864 >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][3]=(16'h52b6 >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][4]=(16'h366d >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][5]=(16'ha4b6 >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][6]=(16'h6d92 >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][7]=(16'hb6db >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][8]=(16'hc71c >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][9]=(16'hf81f >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][10]=(16'hffe0 >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][11]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][12]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][13]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign lut_bank[15][14]=(16'hffff >> range_frac[7:4]) & 1'b1;
assign range_hi=(lut_bank[0] & {15{lut_bank_decode[0]}}) | (lut_bank[1] & {15{lut_bank_decode[1]}}) | (lut_bank[2] & {15{lut_bank_decode[2]}}) | (lut_bank[3] & {15{lut_bank_decode[3]}}) | (lut_bank[4] & {15{lut_bank_decode[4]}}) | (lut_bank[5] & {15{lut_bank_decode[5]}}) | (lut_bank[6] & {15{lut_bank_decode[6]}}) | (lut_bank[7] & {15{lut_bank_decode[7]}}) | (lut_bank[8] & {15{lut_bank_decode[8]}}) | (lut_bank[9] & {15{lut_bank_decode[9]}}) | (lut_bank[10] & {15{lut_bank_decode[10]}}) | (lut_bank[11] & {15{lut_bank_decode[11]}}) | (lut_bank[12] & {15{lut_bank_decode[12]}}) | (lut_bank[13] & {15{lut_bank_decode[13]}}) | (lut_bank[14] & {15{lut_bank_decode[14]}}) | (lut_bank[15] & {15{lut_bank_decode[15]}});
wire [20:0] residual_product=hi_q*residual_q;
wire [28:0] mantissa_q28={hi_q,14'b0}+{8'b0,residual_product};
wire round_increment=mantissa_q28[14] && (|mantissa_q28[13:0] || mantissa_q28[15]);
// RNE low carry is independent of the full mantissa carry-propagate sum.
// No carry enters bit14; when carry15=1, guard14=0, so carry and RNE increment
// are mutually exclusive. Upper increment is precomputed alongside low addition.
wire round_carry=(hi_q[0] & residual_product[14]) |
 ((hi_q[0] ^ residual_product[14]) &
 ((|residual_product[13:0]) | (hi_q[1] ^ residual_product[15])));
wire [6:0] unrounded_low={1'b0,hi_q[6:1]}+{1'b0,residual_product[20:15]};
wire [6:0] round_low={1'b0,hi_q[6:1]}+{1'b0,residual_product[20:15]}+{6'b0,round_carry};
wire [8:0] round_high_inc={1'b0,hi_q[14:7]}+9'd1;
// Preserve the original 29-bit mantissa wrap for arbitrary non-LUT operands.
wire rounded_overflow=round_low[6] && (&hi_q[14:7]) && !unrounded_low[6] && !(hi_q[0] & residual_product[14]);
wire [14:0] rounded_parallel={rounded_overflow,round_low[6] ? round_high_inc[7:0] : hi_q[14:7],round_low[5:0]};
always @(posedge clk) begin
  out_rounded_mant<=PRE_ROUNDED_EXP ? rounded_parallel : 15'b0;
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
