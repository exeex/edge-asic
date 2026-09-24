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
  // Select the low/high logical quartet of each H1 face.  This is a
  // wrapper-supplied bank-route bit, not a tenth SRAM row-address wire.
  input wire [7:0] req_bank_half_i,
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
  reg [3:0] north_half_q, south_half_q;
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
    north_half_q <= h2_link[1] ? req_bank_half_i[7:4]
                               : req_bank_half_i[3:0];
    south_half_q <= h2_link[2] ? req_bank_half_i[3:0]
                               : req_bank_half_i[7:4];
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
  wire [7:0] north_h1_valid, south_h1_valid;
  wire [7:0] north_h1_write, south_h1_write;
  wire [7:0] north_h1_strb, south_h1_strb;
  wire [71:0] north_h1_addr, south_h1_addr;
  wire [63:0] north_h1_data, south_h1_data;
  reg [3:0] north_half_d1_q, north_half_d2_q;
  reg [3:0] south_half_d1_q, south_half_d2_q;
  always @(posedge clk) begin
    north_half_d1_q <= north_half_q;
    north_half_d2_q <= north_half_d1_q;
    south_half_d1_q <= south_half_q;
    south_half_d2_q <= south_half_d1_q;
  end
  genvar half_lane;
  generate for (half_lane=0; half_lane<4; half_lane=half_lane+1) begin: HALF_ROUTE
    assign north_h1_valid[half_lane] = north_valid_q[half_lane] &&
        !north_half_q[half_lane];
    assign north_h1_valid[half_lane+4] = north_valid_q[half_lane] &&
        north_half_q[half_lane];
    assign south_h1_valid[half_lane] = south_valid_q[half_lane] &&
        !south_half_q[half_lane];
    assign south_h1_valid[half_lane+4] = south_valid_q[half_lane] &&
        south_half_q[half_lane];
    assign north_h1_write[half_lane] = north_write_q[half_lane];
    assign north_h1_write[half_lane+4] = north_write_q[half_lane];
    assign south_h1_write[half_lane] = south_write_q[half_lane];
    assign south_h1_write[half_lane+4] = south_write_q[half_lane];
    assign north_h1_strb[half_lane] = north_strb_q[half_lane];
    assign north_h1_strb[half_lane+4] = north_strb_q[half_lane];
    assign south_h1_strb[half_lane] = south_strb_q[half_lane];
    assign south_h1_strb[half_lane+4] = south_strb_q[half_lane];
    assign north_h1_addr[half_lane*9 +: 9] =
        north_addr_q[half_lane*9 +: 9];
    assign north_h1_addr[(half_lane+4)*9 +: 9] =
        north_addr_q[half_lane*9 +: 9];
    assign south_h1_addr[half_lane*9 +: 9] =
        south_addr_q[half_lane*9 +: 9];
    assign south_h1_addr[(half_lane+4)*9 +: 9] =
        south_addr_q[half_lane*9 +: 9];
    assign north_h1_data[half_lane*8 +: 8] =
        north_data_q[half_lane*8 +: 8];
    assign north_h1_data[(half_lane+4)*8 +: 8] =
        north_data_q[half_lane*8 +: 8];
    assign south_h1_data[half_lane*8 +: 8] =
        south_data_q[half_lane*8 +: 8];
    assign south_h1_data[(half_lane+4)*8 +: 8] =
        south_data_q[half_lane*8 +: 8];
  end endgenerate
  assign h1_link[0] = phase_h1_i;
  assign phase_h1_o = h1_link[2];
`ifdef EDGE_SRAM_H1_HARDENED_FACES
  edge_sram_h1_tile4k_north x_north (
`else
  edge_sram_h1_tile4k x_north (
`endif
    .clk(clk), .rst_b(rst_b), .phase_i(h1_link[0]),
    .phase_o(h1_link[1]), .req_valid_i(north_h1_valid),
    .req_write_i(north_h1_write),
    .req_wstrb_i(north_h1_strb),
    .req_addr_i(north_h1_addr),
    .req_wdata_i(north_h1_data),
    .rsp_valid_o(north_rsp_valid), .rsp_data_o(north_rsp_data));
`ifdef EDGE_SRAM_H1_HARDENED_FACES
  edge_sram_h1_tile4k_south x_south (
`else
  edge_sram_h1_tile4k x_south (
`endif
    .clk(clk), .rst_b(rst_b), .phase_i(h1_link[1]),
    .phase_o(h1_link[2]), .req_valid_i(south_h1_valid),
    .req_write_i(south_h1_write),
    .req_wstrb_i(south_h1_strb),
    .req_addr_i(south_h1_addr),
    .req_wdata_i(south_h1_data),
    .rsp_valid_o(south_rsp_valid), .rsp_data_o(south_rsp_data));

  genvar lane;
  generate for (lane=0; lane<4; lane=lane+1) begin: RESPONSE
    wire [7:0] north_byte = north_half_d2_q[lane]
        ? north_rsp_data[(lane+4)*8 +: 8]
        : north_rsp_data[lane*8 +: 8];
    wire [7:0] south_byte = south_half_d2_q[lane]
        ? south_rsp_data[(lane+4)*8 +: 8]
        : south_rsp_data[lane*8 +: 8];
    wire north_valid = north_half_d2_q[lane]
        ? north_rsp_valid[lane+4] : north_rsp_valid[lane];
    wire south_valid = south_half_d2_q[lane]
        ? south_rsp_valid[lane+4] : south_rsp_valid[lane];
    assign rsp_valid_o[lane] = south_tag_d2_q
        ? south_valid : north_valid;
    assign rsp_valid_o[lane+4] = south_tag_d2_q
        ? north_valid : south_valid;
    assign rsp_data_o[lane*8 +: 8] = south_tag_d2_q
        ? south_byte : north_byte;
    assign rsp_data_o[(lane+4)*8 +: 8] = south_tag_d2_q
        ? north_byte : south_byte;
  end endgenerate

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_b && phase_ready_o && (|req_valid_i)) begin
    if (h2_link[1] !== h2_link[2])
      $fatal(1, "H2 phase taps differ after fill");
  end
`endif
endmodule
