// One 512-row depth half: four independent 128-bit pairs, 64 x 512x8.
// Eight 4 KiB H1 tiles expose the full 512-bit physical width.  No depth
// selection or response merge lives below this boundary.
module edge_sram_h1_array32k (
  input wire clk, rst_b, phase_i,
  output wire phase_o,
  input wire [3:0] pair_valid_i, pair_write_i,
  input wire [35:0] pair_addr_i,
  input wire [511:0] pair_wdata_i,
  input wire [63:0] pair_wstrb_i,
  output wire [3:0] pair_rsp_valid_o,
  output wire [511:0] pair_rsp_data_o
);
  wire [8:0] phase_link;
  assign phase_link[0] = phase_i;
  assign phase_o = phase_link[8];
  wire [63:0] tile_rsp_valid;
  wire [511:0] tile_rsp_data;
  genvar group, lane;
  generate for (group=0; group<8; group=group+1) begin: BYTE_GROUP
    wire [7:0] req_valid, req_write, req_strb;
    wire [71:0] req_addr;
    wire [63:0] req_data;
    for (lane=0; lane<8; lane=lane+1) begin: INPUT_LANE
      // H1 exchanges pair 0/2 and 1/3 while retaining both bytes per pair.
      localparam integer BASE_PAIR = (lane/4) + 2*((lane%4)/2);
      localparam integer BYTE_IN_GROUP = lane%2;
      wire [1:0] physical_pair = 2'(BASE_PAIR) ^ {1'b0,phase_i};
      assign req_valid[lane] = pair_valid_i[physical_pair];
      assign req_write[lane] = pair_write_i[physical_pair];
      assign req_strb[lane] = pair_wstrb_i[physical_pair*16
                                           + group*2+BYTE_IN_GROUP];
      assign req_addr[lane*9 +: 9] =
          pair_addr_i[physical_pair*9 +: 9];
      assign req_data[lane*8 +: 8] =
          pair_wdata_i[physical_pair*128
                       + (group*2+BYTE_IN_GROUP)*8 +: 8];
    end
    edge_sram_h1_tile4k x_tile (
      .clk(clk), .rst_b(rst_b), .phase_i(phase_link[group]),
      .phase_o(phase_link[group+1]),
      .req_valid_i(req_valid), .req_write_i(req_write),
      .req_wstrb_i(req_strb), .req_addr_i(req_addr),
      .req_wdata_i(req_data),
      .rsp_valid_o(tile_rsp_valid[group*8 +: 8]),
      .rsp_data_o(tile_rsp_data[group*64 +: 64]));
  end endgenerate

  // Both H1 and the synchronous SRAM read have completed at this point.
  reg swap_d1_q, swap_d2_q;
  always @(posedge clk) begin
    swap_d1_q <= phase_i;
    swap_d2_q <= swap_d1_q;
  end
  genvar pair, byte_lane;
  generate for (pair=0; pair<4; pair=pair+1) begin: RESPONSE_PAIR
    wire [1:0] logical_pair = 2'(pair) ^ {1'b0,swap_d2_q};
    wire [2:0] lane_base = logical_pair[0]*3'd4
                       + logical_pair[1]*3'd2;
    assign pair_rsp_valid_o[pair] = tile_rsp_valid[integer'(lane_base)];
    for (byte_lane=0; byte_lane<16; byte_lane=byte_lane+1) begin: BYTE
      localparam integer GROUP = byte_lane/2;
      localparam integer BYTE_IN_GROUP = byte_lane%2;
      assign pair_rsp_data_o[pair*128+byte_lane*8 +: 8] =
          tile_rsp_data[GROUP*64
                        +(integer'(lane_base)+BYTE_IN_GROUP)*8 +: 8];
    end
  end endgenerate
endmodule
