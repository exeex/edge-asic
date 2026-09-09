// Unified E4 16x16 compute tile composed of two local 8x16 row groups.
module edge_tile16x16_unit #(
  parameter LOCAL_WEIGHT_BUFFER=0,
  parameter TRACK_VALID=1,
  parameter LOCAL_INPUT_FIFO=0
)(
  clk, rst_b, in_valid,rsum_enable_i,rsum_first_i,rsum_last_i,
  activation_i, weight_bf16_mode_i,
  int8_weights_i, bf16_weights_i,
  weight_fill_valid_i,weight_fill_ready_o,weight_fill_data_i,
  weight_activate_i,
  input_fifo_write_valid_i,input_fifo_write_ptr_i,input_fifo_write_data_i,
  input_fifo_read_ptr_i,input_fifo_read_data_o,
  out_valid, output_bf22_o,output_bf16_o
);
wire [1:0] group_fill_ready;
assign weight_fill_ready_o = &group_fill_ready;
input clk, rst_b, in_valid, weight_bf16_mode_i;
input rsum_enable_i,rsum_first_i,rsum_last_i;
input [255:0] activation_i;
input [2047:0] int8_weights_i;
input [4095:0] bf16_weights_i;
input weight_fill_valid_i;
output weight_fill_ready_o;
input weight_activate_i;
input[255:0]weight_fill_data_i;
input input_fifo_write_valid_i;
input[1:0]input_fifo_write_ptr_i,input_fifo_read_ptr_i;
input[255:0]input_fifo_write_data_i;
output[255:0]input_fifo_read_data_o;
output out_valid;
output [351:0] output_bf22_o;
output [255:0] output_bf16_o;

wire group0_valid;
wire group1_valid;
wire [255:0] sanitized_activation;
wire [255:0] local_input_fifo_data;
wire [255:0] selected_activation = LOCAL_INPUT_FIFO
  ? local_input_fifo_data : activation_i;
generate if (TRACK_VALID) begin : VALID_TRACKER
  reg [8:0] valid_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) valid_q <= 0;
    else valid_q <= {valid_q[7:0],in_valid};
  assign out_valid = valid_q[8];
end else begin : EXTERNAL_VALID
  assign out_valid = 1'b0;
end endgenerate

generate
  if (LOCAL_INPUT_FIFO) begin : LOCAL_ACTIVATION_FIFO
    edge_dot16_input_fifo x_input_fifo (
      .clk(clk), .write_valid_i(input_fifo_write_valid_i),
      .write_ptr_i(input_fifo_write_ptr_i),
      .write_data_i(input_fifo_write_data_i),
      .read_ptr_i(input_fifo_read_ptr_i),
      .read_data_o(local_input_fifo_data)
    );
  end else begin : NO_LOCAL_ACTIVATION_FIFO
    assign local_input_fifo_data = 256'b0;
  end
endgenerate
assign input_fifo_read_data_o = LOCAL_INPUT_FIFO
  ? local_input_fifo_data : 256'b0;

genvar fill_lane;
generate
  for(fill_lane=0;fill_lane<16;fill_lane=fill_lane+1)begin:ACTIVATION_SANITIZE
    assign sanitized_activation[fill_lane*16+:16]=
      sanitize_bf16(selected_activation[fill_lane*16+:16]);
  end
endgenerate

edge_dot16_group8 #(.LOCAL_WEIGHT_BUFFER(LOCAL_WEIGHT_BUFFER),.TRACK_VALID(0),.ROW_BASE(0)) x_slice0_rows (
  .clk(clk), .rst_b(rst_b), .in_valid(in_valid),
  .rsum_enable_i(rsum_enable_i),.rsum_first_i(rsum_first_i),
  .rsum_last_i(rsum_last_i),
  .activation_i(sanitized_activation),
  .weight_bf16_mode_i(weight_bf16_mode_i),
  .int8_weights_i(int8_weights_i[1023:0]),
  .bf16_weights_i(bf16_weights_i[2047:0]),
  .weight_fill_valid_i(weight_fill_valid_i && weight_fill_ready_o),
  .weight_fill_ready_o(group_fill_ready[0]),
  .weight_fill_data_i(weight_fill_data_i[127:0]),.weight_activate_i(weight_activate_i),
  .out_valid(group0_valid),.output_bf22_o(output_bf22_o[175:0]),
  .output_bf16_o(output_bf16_o[127:0])
);

edge_dot16_group8 #(.LOCAL_WEIGHT_BUFFER(LOCAL_WEIGHT_BUFFER),.TRACK_VALID(0),.ROW_BASE(8)) x_slice1_rows (
  .clk(clk), .rst_b(rst_b), .in_valid(in_valid),
  .rsum_enable_i(rsum_enable_i),.rsum_first_i(rsum_first_i),
  .rsum_last_i(rsum_last_i),
  .activation_i(sanitized_activation),
  .weight_bf16_mode_i(weight_bf16_mode_i),
  .int8_weights_i(int8_weights_i[2047:1024]),
  .bf16_weights_i(bf16_weights_i[4095:2048]),
  .weight_fill_valid_i(weight_fill_valid_i && weight_fill_ready_o),
  .weight_fill_ready_o(group_fill_ready[1]),
  .weight_fill_data_i(weight_fill_data_i[255:128]),.weight_activate_i(weight_activate_i),
  .out_valid(group1_valid),.output_bf22_o(output_bf22_o[351:176]),
  .output_bf16_o(output_bf16_o[255:128])
);

function [15:0] i8_to_bf16;
  input [7:0] value;reg sign;reg[7:0]mag;reg[2:0]msb;reg[7:0]norm;
  begin sign=value[7];mag=sign?(~value+1'b1):value;msb=0;
    if(mag[7])msb=7;else if(mag[6])msb=6;else if(mag[5])msb=5;
    else if(mag[4])msb=4;else if(mag[3])msb=3;else if(mag[2])msb=2;
    else if(mag[1])msb=1;
    norm=mag<<(7-msb);
    i8_to_bf16=(mag==0)?16'b0:{sign,8'd127+{5'b0,msb},norm[6:0]};
  end
endfunction

function [15:0] sanitize_bf16;
  input [15:0] value;
  begin
    if((value[14:7]==8'hff)&&(value[6:0]!=0))sanitize_bf16=16'h0000;
    else if(value[14:0]==15'h7f80)sanitize_bf16=value[15]?16'hff7f:16'h7f7f;
    else sanitize_bf16=value;
  end
endfunction

endmodule
