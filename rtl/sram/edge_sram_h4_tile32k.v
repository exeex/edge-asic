// Four 8 KiB H2 tiles form two adjacent 128-bit pair positions.  H4 swaps
// those positions through one registered request cut; it never arbitrates.
module edge_sram_h4_phase_hop (
  input wire clk, rst_b, phase_i,
  output wire phase_o
);
  reg [3:0] delay_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) delay_q <= 4'b0;
    else delay_q <= {delay_q[2:0], phase_i};
  assign phase_o = ~delay_q[3];
endmodule

module edge_sram_h4_tile32k #(
  parameter EXPLICIT_SWAP = 0
)(
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
  wire [4:0] h1_link, h2_link, h4_link;
  assign h1_link[0] = phase_h1_i;
  assign h2_link[0] = phase_h2_i;
  assign h4_link[0] = phase_h4_i;
  assign phase_h1_o = h1_link[4];
  assign phase_h2_o = h2_link[4];
  assign phase_h4_o = h4_link[4];

  genvar tile;
  generate for (tile=0; tile<4; tile=tile+1) begin: TILE
    edge_sram_h4_phase_hop x_h4_phase (
      .clk(clk), .rst_b(rst_b), .phase_i(h4_link[tile]),
      .phase_o(h4_link[tile+1]));
  end endgenerate

  // The longest local chain is H1: four H2 children * two H1 faces *
  // eight H1 hops.  Do not admit commands until every leaf has filled.
  reg [6:0] fill_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) fill_q <= 7'd0;
    else if (fill_q != 7'd64) fill_q <= fill_q + 7'd1;
  assign phase_ready_o = (fill_q == 7'd64);

  // Optional request-time commutator control. The response follows the
  // captured swap tag, never the current control. Legacy users keep the
  // canonical phase chain and need not connect swap_i.
  wire swap = EXPLICIT_SWAP ? swap_i : h4_link[2];
  reg [31:0] valid_q, write_q, strb_q, bank_half_q;
  reg [287:0] addr_q;
  reg [255:0] data_q;
  reg swap_q, swap_d1_q, swap_d2_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) valid_q <= 32'b0;
    else valid_q <= {32{phase_ready_o}} &
        (swap ? {req_valid_i[15:0], req_valid_i[31:16]}
              : req_valid_i);
  always @(posedge clk) begin
    write_q <= swap ? {req_write_i[15:0], req_write_i[31:16]}
                    : req_write_i;
    strb_q <= swap ? {req_wstrb_i[15:0], req_wstrb_i[31:16]}
                   : req_wstrb_i;
    bank_half_q <= swap ? {req_bank_half_i[15:0], req_bank_half_i[31:16]}
                        : req_bank_half_i;
    addr_q <= swap ? {req_addr_i[143:0], req_addr_i[287:144]}
                   : req_addr_i;
    data_q <= swap ? {req_wdata_i[127:0], req_wdata_i[255:128]}
                   : req_wdata_i;
    swap_q <= swap;
    swap_d1_q <= swap_q;
    swap_d2_q <= swap_d1_q;
  end

  wire [31:0] child_valid;
  wire [255:0] child_data;
  wire [3:0] child_ready;
  generate for (tile=0; tile<4; tile=tile+1) begin: H2
`ifdef EDGE_SRAM_H2_HARDENED
    edge_sram_h2_tile8k_h4 x_tile (
`else
    edge_sram_h2_tile8k #(.H1_COMMAND_REGISTER(0)) x_tile (
`endif
      .clk(clk), .rst_b(rst_b),
      .phase_h1_i(h1_link[tile]), .phase_h2_i(h2_link[tile]),
      .phase_h1_o(h1_link[tile+1]), .phase_h2_o(h2_link[tile+1]),
      .phase_ready_o(child_ready[tile]),
      .req_valid_i(valid_q[tile*8 +: 8]),
      .req_write_i(write_q[tile*8 +: 8]),
      .req_wstrb_i(strb_q[tile*8 +: 8]),
      .req_bank_half_i(bank_half_q[tile*8 +: 8]),
      .req_addr_i(addr_q[tile*72 +: 72]),
      .req_wdata_i(data_q[tile*64 +: 64]),
      .rsp_valid_o(child_valid[tile*8 +: 8]),
      .rsp_data_o(child_data[tile*64 +: 64]));
  end endgenerate

  assign rsp_valid_o = swap_d2_q
      ? {child_valid[15:0], child_valid[31:16]} : child_valid;
  assign rsp_data_o = swap_d2_q
      ? {child_data[127:0], child_data[255:128]} : child_data;

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_b && phase_ready_o && (|req_valid_i)) begin
    if (phase_h1_o !== phase_h1_i ||
        phase_h2_o !== phase_h2_i ||
        phase_h4_o !== phase_h4_i)
      $fatal(1, "H4 phase tails differ after fill");
    if (child_ready !== 4'hf)
      $fatal(1, "H4 child not ready after fill");
  end
`endif
endmodule
