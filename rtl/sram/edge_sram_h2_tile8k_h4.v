// Two-edge H2 master used by the three-edge H4 physical hierarchy.
module edge_sram_h2_tile8k_h4 (
  input wire clk, rst_b,
  input wire phase_h1_i, phase_h2_i,
  output wire phase_h1_o, phase_h2_o,
  output wire phase_ready_o,
  input wire [7:0] req_valid_i, req_write_i, req_wstrb_i,
  // Select the low/high logical quartet of each H1 face.  This is a
  // wrapper-supplied bank-route bit, not a tenth SRAM row-address wire.
  input wire [7:0] req_bank_half_i,
  input wire [71:0] req_addr_i,
  input wire [63:0] req_wdata_i,
  output wire [7:0] rsp_valid_o,
  output wire [63:0] rsp_data_o
);
  edge_sram_h2_tile8k #(.H1_COMMAND_REGISTER(0)) x_h2 (
    .clk(clk),
    .rst_b(rst_b),
    .phase_h1_i(phase_h1_i),
    .phase_h2_i(phase_h2_i),
    .phase_h1_o(phase_h1_o),
    .phase_h2_o(phase_h2_o),
    .phase_ready_o(phase_ready_o),
    .req_valid_i(req_valid_i),
    .req_write_i(req_write_i),
    .req_wstrb_i(req_wstrb_i),
    .req_bank_half_i(req_bank_half_i),
    .req_addr_i(req_addr_i),
    .req_wdata_i(req_wdata_i),
    .rsp_valid_o(rsp_valid_o),
    .rsp_data_o(rsp_data_o)
  );
endmodule
