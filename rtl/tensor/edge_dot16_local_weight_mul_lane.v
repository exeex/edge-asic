// One full-BF16 local weight lane.  Only the narrow fill control/data for this
// lane enters the leaf; active-bank selection is shared by the owning row.
module edge_dot16_local_weight_mul_lane #(
  parameter FPGA_DSP_MUL = 0
)(
  input         clk,
  input         rst_b,
  input         fill_valid_i,
  output [8:0] shift_weight_o,
  input  [8:0]  fill_weight_i,
  input         active_bank_i,
  input  [15:0] activation_i,
  output [15:0] active_weight_o,
  output [15:0] product_o,
  output        product_sign_o
);
reg [8:0] weight_bank0_q;
reg [8:0] weight_bank1_q;
wire [8:0] active_weight = active_bank_i ? weight_bank1_q : weight_bank0_q;
assign shift_weight_o = active_bank_i ? weight_bank0_q : weight_bank1_q;
wire [7:0] active_sig = active_weight[7:0];
// Only numerical nonzero is consumed by the shared external-product path.
assign active_weight_o = {active_weight[8],7'b0,active_weight[7:0]};
wire [7:0] activation_sig = (activation_i[14:7] == 0)
  ? {1'b0,activation_i[6:0]} : {1'b1,activation_i[6:0]};
// Reuse the s0 boundary for selected operands rather than a completed product.
// Relay operands at s1 and multiply into s2 beside the central max/shift island.
reg [7:0] activation_sig_q, weight_sig_q;
reg product_sign_q;
always @(posedge clk) begin
    activation_sig_q <= activation_sig;
    weight_sig_q <= active_sig;
    product_sign_q <= activation_i[15] ^ active_weight[8];
end
reg [7:0] activation_sig_s1_q, weight_sig_s1_q;
reg product_sign_s1_q;
always @(posedge clk) begin
  activation_sig_s1_q <= activation_sig_q;
  weight_sig_s1_q <= weight_sig_q;
  product_sign_s1_q <= product_sign_q;
end
edge_bf16_sig_mul #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_sig_mul (
  .activation_sig_i(activation_sig_s1_q),
  .weight_sig_i(weight_sig_s1_q),
  .product_o(product_o)
);
assign product_sign_o = product_sign_s1_q;
always @(posedge clk) begin
  if (fill_valid_i) begin
    if (!active_bank_i) weight_bank1_q <= fill_weight_i;
    else weight_bank0_q <= fill_weight_i;
  end
end
endmodule

