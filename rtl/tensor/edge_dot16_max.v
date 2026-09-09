// S0 exponent sums, S1 four radix-4 maxima, S2 final max and narrow shift.
module edge_dot16_max(input clk,
 input [127:0] activation_exp_i,weight_exp_i,
 input [15:0] activation_nonzero_i,weight_nonzero_i,
 input weight_bf16_mode_i,
 output reg signed [9:0] max_exp_o,
 output reg [95:0] shift_o);
wire signed [9:0] maximum;
wire [175:0] shifts;
edge_dot_exp_parallel #(.LANES(16)) x_exp(
 .clk(clk),.rst_b(1'b1),.activation_exp_i(activation_exp_i),.weight_exp_i(weight_exp_i),
 .activation_nonzero_i(activation_nonzero_i),.weight_nonzero_i(weight_nonzero_i),
 .weight_bf16_mode_i(weight_bf16_mode_i),.max_exp_o(maximum),.shift_o(shifts));
always @(posedge clk) max_exp_o<=maximum;
genvar i;
generate for(i=0;i<16;i=i+1) begin: SHIFT
 always @(posedge clk) shift_o[i*6+:6]<={($signed(shifts[i*11+:11])>=11'sd19),shifts[i*11+:5]};
end endgenerate
endmodule
