// Fixed explicit-swap physical master; canonical phase spine is unchanged.
module edge_sram_h4_wide_tile32k (

  input wire clk, rst_b,
  input wire swap_i,
  input wire phase_h1_i, phase_h2_i, phase_h4_i,
  output wire phase_h1_o, phase_h2_o, phase_h4_o,
  output wire phase_ready_o,
  input wire [31:0] req_valid_i, req_write_i, req_wstrb_i,
  input wire [31:0] req_bank_half_i,
  input wire [287:0] req_addr_i,
  input wire [255:0] req_wdata_i,
  output wire [31:0] rsp_valid_o,
  output wire [255:0] rsp_data_o
);
  edge_sram_h4_tile32k #(.EXPLICIT_SWAP(1)) x_core (
    .clk(clk),
    .rst_b(rst_b),
    .swap_i(swap_i),
    .phase_h1_i(phase_h1_i),
    .phase_h2_i(phase_h2_i),
    .phase_h4_i(phase_h4_i),
    .phase_h1_o(phase_h1_o),
    .phase_h2_o(phase_h2_o),
    .phase_h4_o(phase_h4_o),
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
