// Result FIFO storage after scale/PSUM/RSUM. E4 owns occupancy and pointers.
module edge_dot16_output_fifo #(parameter WIDTH=256,parameter DEPTH=16,
 parameter PTR_WIDTH=(DEPTH<=2)?1:$clog2(DEPTH))(
 input clk,input write_valid_i,input [PTR_WIDTH-1:0] write_ptr_i,
 input [WIDTH-1:0] write_data_i,input [PTR_WIDTH-1:0] read_ptr_i,
 output [WIDTH-1:0] read_data_o);
reg [WIDTH-1:0] data_q[0:DEPTH-1];
always @(posedge clk) if(write_valid_i) data_q[write_ptr_i]<=write_data_i;
assign read_data_o=data_q[read_ptr_i];
endmodule
