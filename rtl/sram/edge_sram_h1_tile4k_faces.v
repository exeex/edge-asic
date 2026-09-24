// Physically distinct masters with identical H1 behavior and pin bit order.
// The north/south distinction is owned by their APR pin/LEF views, not RTL.
module edge_sram_h1_tile4k_north (
  input wire clk, rst_b, phase_i,
  output wire phase_o,
  input wire [7:0] req_valid_i, req_write_i, req_wstrb_i,
  input wire [71:0] req_addr_i,
  input wire [63:0] req_wdata_i,
  output wire [7:0] rsp_valid_o,
  output wire [63:0] rsp_data_o
);
  edge_sram_h1_tile4k x_tile (
    .clk(clk), .rst_b(rst_b), .phase_i(phase_i), .phase_o(phase_o),
    .req_valid_i(req_valid_i), .req_write_i(req_write_i),
    .req_wstrb_i(req_wstrb_i), .req_addr_i(req_addr_i),
    .req_wdata_i(req_wdata_i), .rsp_valid_o(rsp_valid_o),
    .rsp_data_o(rsp_data_o));
endmodule

module edge_sram_h1_tile4k_south (
  input wire clk, rst_b, phase_i,
  output wire phase_o,
  input wire [7:0] req_valid_i, req_write_i, req_wstrb_i,
  input wire [71:0] req_addr_i,
  input wire [63:0] req_wdata_i,
  output wire [7:0] rsp_valid_o,
  output wire [63:0] rsp_data_o
);
  edge_sram_h1_tile4k x_tile (
    .clk(clk), .rst_b(rst_b), .phase_i(phase_i), .phase_o(phase_o),
    .req_valid_i(req_valid_i), .req_write_i(req_write_i),
    .req_wstrb_i(req_wstrb_i), .req_addr_i(req_addr_i),
    .req_wdata_i(req_wdata_i), .rsp_valid_o(rsp_valid_o),
    .rsp_data_o(rsp_data_o));
endmodule
