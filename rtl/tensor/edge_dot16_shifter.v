// S3 coarse alignment; S4 fine RNE alignment and signed 19-bit lane values.
module edge_dot16_shifter(input clk,input [255:0] product_i,input [15:0] sign_i,
 input [95:0] shift_i,input signed [9:0] max_exp_i,
 output reg [303:0] aligned_o,output reg signed [9:0] max_exp_o);
reg signed [9:0] exp_q;
always @(posedge clk) begin exp_q<=max_exp_i;max_exp_o<=exp_q;end
genvar i;
generate for(i=0;i<16;i=i+1) begin: LANE
 wire [17:0] coarse;wire [2:0] fine;wire guard_bit,sticky,zero;
 reg [17:0] coarse_q;reg [2:0] fine_q;reg guard_q,sticky_q,zero_q,sign_q;
 wire signed [20:0] aligned;
 edge_dot_align_lane_coarse #(.ALIGN_GUARD_BITS(2),.ENCODED_SHIFT(1)) x_coarse(
 .product_i(product_i[i*16+:16]),.shift_amount_i({5'b0,shift_i[i*6+:6]}),
 .coarse_o(coarse),.fine_o(fine),.coarse_guard_o(guard_bit),.coarse_sticky_o(sticky),.force_zero_o(zero));
 edge_dot_align_lane_fine x_fine(.coarse_i(coarse_q),.fine_i(fine_q),
 .coarse_guard_i(guard_q),.coarse_sticky_i(sticky_q),.force_zero_i(zero_q),.sign_i(sign_q),.aligned_o(aligned));
 always @(posedge clk) begin
 coarse_q<=coarse;fine_q<=fine;guard_q<=guard_bit;sticky_q<=sticky;zero_q<=zero;sign_q<=sign_i[i];
 aligned_o[i*19+:19]<=aligned[18:0];
 end
end endgenerate
endmodule
