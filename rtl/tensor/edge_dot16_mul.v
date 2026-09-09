// S0/S1 operand captures, S2 unsigned 8x8 products plus independent signs.
// Local weight leaves supply their own S0/S1 captures in external mode.
module edge_dot16_mul #(parameter LOCAL_WEIGHT_BUFFER=1, parameter FPGA_DSP_MUL=0)(
 input clk,input [127:0] activation_sig_i,weight_sig_i,input [15:0] sign_i,
 input [255:0] activation_i,input fill_valid_i,input [8:0] fill_weight_i,input active_bank_i,
 output [255:0] active_weight_o,
 output reg [255:0] product_o,output reg [15:0] sign_o);
wire [152:0] weight_shift;
assign weight_shift[152:144]=fill_weight_i;
genvar i;
generate for(i=0;i<16;i=i+1) begin: LANE
 if(LOCAL_WEIGHT_BUFFER) begin: LOCAL
  wire [15:0] product;wire sign_bit;
  edge_dot16_local_weight_mul_lane #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_weight_mul_lane(
   .clk(clk),.rst_b(1'b1),.fill_valid_i(fill_valid_i),
   .shift_weight_o(weight_shift[i*9+:9]),.fill_weight_i(weight_shift[(i+1)*9+:9]),
   .active_bank_i(active_bank_i),.activation_i(activation_i[i*16+:16]),
   .active_weight_o(active_weight_o[i*16+:16]),.product_o(product),.product_sign_o(sign_bit));
  always @(posedge clk) begin
   product_o[i*16+:16]<=product;
   sign_o[i]<=sign_bit;
  end
 end else begin: DIRECT
  assign active_weight_o[i*16+:16]=0;
  assign weight_shift[i*9+:9]=0;
  reg [7:0] a0,w0,a1,w1; reg s0,s1;
  wire [15:0] product;
  always @(posedge clk) begin
   a0<=activation_sig_i[i*8+:8];w0<=weight_sig_i[i*8+:8];s0<=sign_i[i];
   a1<=a0;w1<=w0;s1<=s0;
   product_o[i*16+:16]<=product;sign_o[i]<=s1;
  end
  edge_bf16_sig_mul #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_mul(
   .activation_sig_i(a1),.weight_sig_i(w1),.product_o(product));
 end
end endgenerate
endmodule
