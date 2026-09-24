// Two 4 KiB H1 faces form one time-rotated 8 KiB H2 tile.  The eight input
// lanes carry only 9-bit SRAM row addresses: H2 exchanges the two four-lane
// groups between faces, and H1 chooses the quartet inside each face.
module edge_sram_h2_phase_hop (
  input wire clk, rst_b, phase_i,
  output wire phase_o
);
  reg [1:0] delay_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) delay_q <= 2'b0;
    else delay_q <= {delay_q[0], phase_i};
  assign phase_o = ~delay_q[1];
endmodule

module edge_sram_h2_tile8k (
  input wire clk, rst_b,
  input wire phase_h1_i, phase_h2_i,
  output wire phase_h1_o, phase_h2_o,
  output wire phase_ready_o,
  input wire [7:0] req_valid_i, req_write_i, req_wstrb_i,
  input wire [71:0] req_addr_i,
  input wire [63:0] req_wdata_i,
  output wire [7:0] rsp_valid_o,
  output wire [63:0] rsp_data_o
);
  // One H=2 hop beside each face.  Once filled, both taps equal the root
  // H2 bit when the root changes exactly once every two cycles.
  wire [2:0] h2_link;
  assign h2_link[0] = phase_h2_i;
  assign phase_h2_o = h2_link[2];
  edge_sram_h2_phase_hop x_north_h2 (
    .clk(clk), .rst_b(rst_b), .phase_i(h2_link[0]),
    .phase_o(h2_link[1]));
  edge_sram_h2_phase_hop x_south_h2 (
    .clk(clk), .rst_b(rst_b), .phase_i(h2_link[1]),
    .phase_o(h2_link[2]));

  // Four active clocks fill the two H=2 hops.  A reset or work-mode wake
  // must restart the root and this tile together before raw requests resume.
  reg [2:0] fill_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) fill_q <= 3'd0;
    else if (fill_q != 3'd4) fill_q <= fill_q + 3'd1;
  assign phase_ready_o = (fill_q == 3'd4);

  // H2 is one registered request cut per face.  Four lanes reach each face
  // concurrently; the two local taps exchange which logical quartet they
  // take.  H1 then exchanges its four active input lanes between the face's
  // two physical quartets.  Only valid needs reset.
  reg [3:0] north_valid_q, south_valid_q;
  reg [3:0] north_write_q, south_write_q;
  reg [3:0] north_strb_q, south_strb_q;
  reg [35:0] north_addr_q, south_addr_q;
  reg [31:0] north_data_q, south_data_q;
  reg south_tag_q, south_tag_d1_q, south_tag_d2_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) begin
      north_valid_q <= 4'b0;
      south_valid_q <= 4'b0;
    end else begin
      north_valid_q <= {4{phase_ready_o}} &
          (h2_link[1] ? req_valid_i[7:4] : req_valid_i[3:0]);
      south_valid_q <= {4{phase_ready_o}} &
          (h2_link[2] ? req_valid_i[3:0] : req_valid_i[7:4]);
    end
  always @(posedge clk) begin
    north_write_q <= h2_link[1] ? req_write_i[7:4] : req_write_i[3:0];
    south_write_q <= h2_link[2] ? req_write_i[3:0] : req_write_i[7:4];
    north_strb_q <= h2_link[1] ? req_wstrb_i[7:4] : req_wstrb_i[3:0];
    south_strb_q <= h2_link[2] ? req_wstrb_i[3:0] : req_wstrb_i[7:4];
    north_addr_q <= h2_link[1] ? req_addr_i[71:36] : req_addr_i[35:0];
    south_addr_q <= h2_link[2] ? req_addr_i[35:0] : req_addr_i[71:36];
    north_data_q <= h2_link[1] ? req_wdata_i[63:32] : req_wdata_i[31:0];
    south_data_q <= h2_link[2] ? req_wdata_i[31:0] : req_wdata_i[63:32];
    south_tag_q <= h2_link[2];
    south_tag_d1_q <= south_tag_q;
    south_tag_d2_q <= south_tag_d1_q;
  end

  wire [2:0] h1_link;
  wire [7:0] north_rsp_valid, south_rsp_valid;
  wire [63:0] north_rsp_data, south_rsp_data;
  assign h1_link[0] = phase_h1_i;
  assign phase_h1_o = h1_link[2];
`ifdef EDGE_SRAM_H1_HARDENED_FACES
  edge_sram_h1_tile4k_north x_north (
`else
  edge_sram_h1_tile4k x_north (
`endif
    .clk(clk), .rst_b(rst_b), .phase_i(h1_link[0]),
    .phase_o(h1_link[1]), .req_valid_i({4'b0,north_valid_q}),
    .req_write_i({4'b0,north_write_q}),
    .req_wstrb_i({4'b0,north_strb_q}),
    .req_addr_i({36'b0,north_addr_q}),
    .req_wdata_i({32'b0,north_data_q}),
    .rsp_valid_o(north_rsp_valid), .rsp_data_o(north_rsp_data));
`ifdef EDGE_SRAM_H1_HARDENED_FACES
  edge_sram_h1_tile4k_south x_south (
`else
  edge_sram_h1_tile4k x_south (
`endif
    .clk(clk), .rst_b(rst_b), .phase_i(h1_link[1]),
    .phase_o(h1_link[2]), .req_valid_i({4'b0,south_valid_q}),
    .req_write_i({4'b0,south_write_q}),
    .req_wstrb_i({4'b0,south_strb_q}),
    .req_addr_i({36'b0,south_addr_q}),
    .req_wdata_i({32'b0,south_data_q}),
    .rsp_valid_o(south_rsp_valid), .rsp_data_o(south_rsp_data));

  genvar lane;
  generate for (lane=0; lane<4; lane=lane+1) begin: RESPONSE
    assign rsp_valid_o[lane] = south_tag_d2_q
        ? south_rsp_valid[lane] : north_rsp_valid[lane];
    assign rsp_valid_o[lane+4] = south_tag_d2_q
        ? north_rsp_valid[lane] : south_rsp_valid[lane];
    assign rsp_data_o[lane*8 +: 8] = south_tag_d2_q
        ? south_rsp_data[lane*8 +: 8]
        : north_rsp_data[lane*8 +: 8];
    assign rsp_data_o[(lane+4)*8 +: 8] = south_tag_d2_q
        ? north_rsp_data[lane*8 +: 8]
        : south_rsp_data[lane*8 +: 8];
  end endgenerate

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_b && phase_ready_o && (|req_valid_i)) begin
    if (h2_link[1] !== h2_link[2])
      $fatal(1, "H2 phase taps differ after fill");
  end
`endif
endmodule
