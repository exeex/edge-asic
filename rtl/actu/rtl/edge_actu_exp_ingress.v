`timescale 1ns/1ps

// Three captures: native subtraction (2), then EXP range (1).
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
wire [21:0] delta_bf22;
wire delta_valid;
reg [2:0] mode_q [0:1];
reg [15:0] value_q [0:1];
reg [21:0] scalar_q [0:1];
reg [1:0] last_q, clear_q;
function [21:0] exp_operand;
  input [15:0] value;
  input [2:0] mode;
  input [21:0] delta;
  reg [15:0] scaled;
  begin
    scaled={1'b1,value[14:0]};
    if (mode==3'd4 && value[14:0]!=0) begin
      if (value[14:7]<8'hfe) scaled={1'b1,value[14:7]+8'd1,value[6:0]};
      else scaled=16'hff80;
    end
    if (mode==3'd5) exp_operand=delta;
    else if (mode==3'd2 || mode==3'd3 || mode==3'd4) exp_operand={scaled,6'b0};
    else exp_operand={value,6'b0};
  end
endfunction
edge_actu_softmax_sub_bf16_pipe x_delta (
  .clk(clk),.cpurst_b(cpurst_b),.in_valid(in_valid),
  .value_bf16(in_value_bf16),.max_bf16(in_scalar_bits[31:16]),
  .out_valid(delta_valid),.delta_bf22(delta_bf22)
);
wire range_underflow;
wire signed [9:0] range_k;
wire [11:0] range_frac;
edge_actu_exp_range_bf22 x_range (
  .value_bf22(exp_operand(value_q[1],mode_q[1],delta_bf22)),
  .underflow(range_underflow),.exp2_k(range_k),.frac_code(range_frac)
);
always @(posedge clk) begin
  mode_q[0]<=in_mode; mode_q[1]<=mode_q[0];
  value_q[0]<=in_value_bf16; value_q[1]<=value_q[0];
  // Only normalize carries an internal BF22 sum. External max/epsilon are BF16.
  scalar_q[0]<=(in_mode==3'd7) ? in_scalar_bits[31:10] : {in_scalar_bits[31:16],6'b0}; scalar_q[1]<=scalar_q[0];
  out_mode<=mode_q[1]; out_value_bf16<=value_q[1];
  out_scalar_bf22<=scalar_q[1];
  out_underflow<=range_underflow; out_exp2_k<=range_k; out_frac_code<=range_frac;
end
always @(posedge clk or negedge cpurst_b)
  if (!cpurst_b) begin
    out_valid<=1'b0; last_q<=0; clear_q<=0; out_last<=0; out_sum_clear<=0;
  end else begin
    out_valid<=delta_valid;
    last_q<={last_q[0],in_last}; clear_q<={clear_q[0],in_sum_clear};
    out_last<=last_q[1]; out_sum_clear<=clear_q[1];
  end
endmodule
