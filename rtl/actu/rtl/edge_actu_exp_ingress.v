`timescale 1ns/1ps

// Six captures: BF16 subtract decode/align/add/pack, Q16 prepare, scale.
// Every mode and sideband takes the same path; scalar epsilon is BF16, while the retained sum is BF22.
module edge_actu_exp_ingress (
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
  output reg [11:0] out_frac_code
);
wire [15:0] delta_bf16;
wire delta_valid;
reg [21:0] native_operand_q [0:3];
reg [22:0] magnitude_q16_q;
reg sign_q, underflow_q;
reg [4:0] valid_q;
reg [2:0] mode_q [0:4];
reg [15:0] value_q [0:4];
reg [21:0] scalar_q [0:4];
reg [4:0] last_q, clear_q;
integer stage;
function [21:0] native_exp_operand;
  input [15:0] value;
  input [2:0] mode;
  reg [15:0] scaled;
  begin
    scaled={1'b1,value[14:0]};
    if (mode==3'd4 && value[14:0]!=0) begin
      if (value[14:7]<8'hfe) scaled={1'b1,value[14:7]+8'd1,value[6:0]};
      else scaled=16'hff80;
    end
    if (mode==3'd2 || mode==3'd3 || mode==3'd4) native_exp_operand={scaled,6'b0};
    else native_exp_operand={value,6'b0};
  end
endfunction
// G0..G3: one dedicated capture per subtract operation, single BF16 RNE.
edge_actu_softmax_sub_bf16_pipe x_subtract (
  .clk(clk),.cpurst_b(cpurst_b),.in_valid(in_valid),
  .value_bf16(in_value_bf16),.max_bf16(in_scalar_bits[31:16]),
  .out_valid(delta_valid),.delta_bf16(delta_bf16)
);
wire range_underflow, range_sign;
wire [22:0] range_magnitude;
wire signed [9:0] range_k;
wire [11:0] range_frac;
// G4 selects the BF16-rounded difference and captures bounded Q16.
edge_actu_exp_range_bf22_prepare x_range_prepare (
  .value_bf22(mode_q[3]==3'd5 ? {delta_bf16,6'b0} : native_operand_q[3]),
  .underflow(range_underflow),.sign_z(range_sign),.magnitude_q16(range_magnitude)
);
// G5 has only registered fixed-point inputs: no mode mux or FP decode here.
edge_actu_exp_range_bf22_scale x_range_scale (
  .sign_z(sign_q),.magnitude_q16(magnitude_q16_q),
  .exp2_k(range_k),.frac_code(range_frac)
);
always @(posedge clk) begin
  native_operand_q[0]<=native_exp_operand(in_value_bf16,in_mode);
  for(stage=1;stage<4;stage=stage+1)native_operand_q[stage]<=native_operand_q[stage-1];
  magnitude_q16_q<=range_magnitude; sign_q<=range_sign; underflow_q<=range_underflow;
  mode_q[0]<=in_mode;
  value_q[0]<=in_value_bf16;
  // Only normalize carries an internal BF22 sum. External max/epsilon are BF16.
  scalar_q[0]<=(in_mode==3'd7) ? in_scalar_bits[31:10] : {in_scalar_bits[31:16],6'b0};
  for(stage=1;stage<5;stage=stage+1)begin
    mode_q[stage]<=mode_q[stage-1];value_q[stage]<=value_q[stage-1];scalar_q[stage]<=scalar_q[stage-1];
  end
  out_mode<=mode_q[4]; out_value_bf16<=value_q[4];
  out_scalar_bf22<=scalar_q[4];
  out_underflow<=underflow_q; out_exp2_k<=range_k; out_frac_code<=range_frac;
end
always @(posedge clk or negedge cpurst_b)
  if (!cpurst_b) begin
    out_valid<=1'b0; valid_q<=0; last_q<=0; clear_q<=0; out_last<=0; out_sum_clear<=0;
  end else begin
    valid_q<={valid_q[3:0],in_valid};
    out_valid<=valid_q[4];
    last_q<={last_q[3:0],in_last}; clear_q<={clear_q[3:0],in_sum_clear};
    out_last<=last_q[4]; out_sum_clear<=clear_q[4];
  end
endmodule
