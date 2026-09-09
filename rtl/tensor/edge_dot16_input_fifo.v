// One 16-bit slice of the moved four-entry activation FIFO.  The sixteen
// slices are intended to sit side-by-side under sixteen evenly spaced north
// pin groups, so input storage and southbound routing share the same lane.
module edge_dot16_input_fifo_lane(
  input         clk,
  input         write_valid_i,
  input  [1:0]  write_ptr_i,
  input  [15:0] write_data_i,
  input  [1:0]  read_ptr_i,
  output [15:0] read_data_o
);
reg [15:0] data_q [0:3];
always @(posedge clk) begin
  if (write_valid_i) data_q[write_ptr_i] <= write_data_i;
end
assign read_data_o = data_q[read_ptr_i];
endmodule

module edge_dot16_input_fifo(
  input          clk,
  input          write_valid_i,
  input  [1:0]   write_ptr_i,
  input  [255:0] write_data_i,
  input  [1:0]   read_ptr_i,
  output [255:0] read_data_o
);
genvar fifo_lane;
generate
  for (fifo_lane = 0; fifo_lane < 16; fifo_lane = fifo_lane + 1) begin
    : ACTIVATION_FIFO_LANE
    edge_dot16_input_fifo_lane x_lane (
      .clk(clk), .write_valid_i(write_valid_i),
      .write_ptr_i(write_ptr_i),
      .write_data_i(write_data_i[fifo_lane*16 +: 16]),
      .read_ptr_i(read_ptr_i),
      .read_data_o(read_data_o[fifo_lane*16 +: 16])
    );
  end
endgenerate
endmodule

