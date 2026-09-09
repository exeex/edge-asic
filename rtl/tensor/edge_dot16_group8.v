// One physically local E4 row group: eight dot16 rows beside one DTCM slice.
module edge_dot16_group8 #(
  parameter LOCAL_WEIGHT_BUFFER=0,
  parameter TRACK_VALID=1,
  parameter ROW_BASE=0
)(
  clk, rst_b, in_valid,rsum_enable_i,rsum_first_i,rsum_last_i,
  activation_i, weight_bf16_mode_i,
  int8_weights_i, bf16_weights_i,
  weight_fill_valid_i,weight_fill_ready_o,weight_fill_data_i,
  weight_activate_i,
  out_valid, output_bf20_o
);
input clk, rst_b, in_valid, weight_bf16_mode_i;
input rsum_enable_i,rsum_first_i,rsum_last_i;
input [255:0] activation_i;
input [1023:0] int8_weights_i;
input [2047:0] bf16_weights_i;
input weight_fill_valid_i;
output weight_fill_ready_o;
input weight_activate_i;
input[127:0]weight_fill_data_i;
output out_valid;
output [159:0] output_bf20_o;

wire [7:0] row_valid, row_fill_ready;
assign weight_fill_ready_o = &row_fill_ready;

generate if (TRACK_VALID) begin : VALID_TRACKER
  reg [8:0] valid_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) valid_q <= 0;
    else valid_q <= {valid_q[7:0],in_valid};
  assign out_valid = valid_q[8];
end else begin : EXTERNAL_VALID
  assign out_valid = 1'b0;
end endgenerate

genvar row;
generate
  for (row = 0; row < 8; row = row + 1) begin : ROW
    edge_dot16_kernel #(.LOCAL_WEIGHT_BUFFER(LOCAL_WEIGHT_BUFFER),.TRACK_VALID(0),
      .ROW_INDEX(ROW_BASE+row)) x_dot16 (
      .clk(clk), .rst_b(rst_b), .in_valid(in_valid),
      .rsum_enable_i(rsum_enable_i),.rsum_first_i(rsum_first_i),
      .rsum_last_i(rsum_last_i),
      .bf16_vec_lo_i(activation_i[127:0]),
      .bf16_vec_hi_i(activation_i[255:128]),
      .int8_vec_lo_i(int8_weights_i[row*128 +: 64]),
      .int8_vec_hi_i(int8_weights_i[row*128 + 64 +: 64]),
      .weight_bf16_mode_i(weight_bf16_mode_i),
      .bf16_weight_vec_lo_i(bf16_weights_i[row*256 +: 128]),
      .bf16_weight_vec_hi_i(bf16_weights_i[row*256 + 128 +: 128]),
      .weight_fill_valid_i(weight_fill_valid_i && weight_fill_ready_o),
      .weight_fill_ready_o(row_fill_ready[row]),
      .weight_fill_data_i(weight_fill_data_i[row*16+:16]),
      .weight_activate_i(weight_activate_i),
      .out_valid(row_valid[row]),
      .bf20_o(output_bf20_o[row*20 +: 20])
    );
  end
endgenerate
endmodule
