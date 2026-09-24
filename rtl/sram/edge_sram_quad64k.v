// 64 KiB physical fragment: four 128-bit pair positions, 1024 rows each.
// Sixteen H1 tiles cover 2 depth halves x 8 two-byte groups.  The incoming
// pair boundary is registered (an H2 timing cut); the H1 cut and SRAM capture
// add the next two clocks.  A compatibility wrapper owns the preceding H4
// cut and the inverse channel rotation.  H2 mux locality is not yet an APR
// claim: the first version accepts already-permuted physical pair commands.
module edge_sram_quad64k (
  input wire clk, rst_b, phase_i,
  output wire phase_o,
  input wire [3:0] pair_valid_i, pair_write_i,
  input wire [39:0] pair_addr_i,
  input wire [511:0] pair_wdata_i,
  input wire [63:0] pair_wstrb_i,
  output wire [3:0] pair_rsp_valid_o,
  output wire [511:0] pair_rsp_data_o
);
  reg [3:0] pair_valid_q, pair_write_q;
  reg [39:0] pair_addr_q;
  reg [511:0] pair_wdata_q;
  reg [63:0] pair_wstrb_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) pair_valid_q <= 4'b0;
    else pair_valid_q <= pair_valid_i;
  always @(posedge clk) begin
    pair_write_q <= pair_write_i;
    pair_addr_q <= pair_addr_i;
    pair_wdata_q <= pair_wdata_i;
    pair_wstrb_q <= pair_wstrb_i;
  end

  wire [16:0] phase_link;
  assign phase_link[0] = phase_i;
  assign phase_o = phase_link[16];
  wire [127:0] tile_rsp_valid;
  wire [1023:0] tile_rsp_data;
  genvar depth, group, lane;
  generate for (depth=0; depth<2; depth=depth+1) begin: DEPTH
    for (group=0; group<8; group=group+1) begin: BYTE_GROUP
      localparam integer TILE = depth*8+group;
      wire [7:0] req_valid, req_write, req_strb;
      wire [71:0] req_addr;
      wire [63:0] req_data;
      for (lane=0; lane<8; lane=lane+1) begin: INPUT_LANE
        // Lanes 0..3 are pair 0/2, lanes 4..7 are pair 1/3.
        // Pre-permute the pair index so the H1 butterfly lands on the
        // requested physical pair after the single-bit phase exchange.
        localparam integer BASE_PAIR = (lane/4) + 2*((lane%4)/2);
        localparam integer BYTE_IN_GROUP = lane%2;
        wire [1:0] physical_pair = 2'(BASE_PAIR) ^ {1'b0,phase_i};
        assign req_valid[lane] = pair_valid_q[physical_pair]
            && (pair_addr_q[physical_pair*10+9] == 1'(depth));
        assign req_write[lane] = pair_write_q[physical_pair];
        assign req_strb[lane] = pair_wstrb_q[physical_pair*16
                                             + group*2+BYTE_IN_GROUP];
        assign req_addr[lane*9 +: 9] =
            pair_addr_q[physical_pair*10 +: 9];
        assign req_data[lane*8 +: 8] =
            pair_wdata_q[physical_pair*128
                         + (group*2+BYTE_IN_GROUP)*8 +: 8];
      end
      edge_sram_h1_tile4k x_tile (
        .clk(clk), .rst_b(rst_b), .phase_i(phase_link[TILE]),
        .phase_o(phase_link[TILE+1]),
        .req_valid_i(req_valid), .req_write_i(req_write),
        .req_wstrb_i(req_strb), .req_addr_i(req_addr),
        .req_wdata_i(req_data),
        .rsp_valid_o(tile_rsp_valid[TILE*8 +: 8]),
        .rsp_data_o(tile_rsp_data[TILE*64 +: 64]));
    end
  end endgenerate

  // These tags describe the H1 issue at the tile input, two clocks before
  // the synchronous SRAM result.  Only valid needs reset.
  reg swap_d1_q, swap_d2_q;
  reg [3:0] depth_d1_q, depth_d2_q;
  always @(posedge clk) begin
    swap_d1_q <= phase_i;
    swap_d2_q <= swap_d1_q;
    for (integer p=0; p<4; p=p+1) begin
      depth_d1_q[p] <= pair_addr_q[p*10+9];
      depth_d2_q[p] <= depth_d1_q[p];
    end
  end
  genvar pair, byte_lane;
  generate for (pair=0; pair<4; pair=pair+1) begin: RESPONSE_PAIR
    wire [1:0] logical_pair = 2'(pair) ^ {1'b0,swap_d2_q};
    wire [2:0] lane_base = logical_pair[0]*3'd4
                         + logical_pair[1]*3'd2;
    assign pair_rsp_valid_o[pair] =
        tile_rsp_valid[integer'(depth_d2_q[pair])*64 + integer'(lane_base)];
    for (byte_lane=0; byte_lane<16; byte_lane=byte_lane+1) begin: BYTE
      localparam integer GROUP = byte_lane/2;
      localparam integer BYTE_IN_GROUP = byte_lane%2;
      assign pair_rsp_data_o[pair*128+byte_lane*8 +: 8] =
          tile_rsp_data[(integer'(depth_d2_q[pair])*8+GROUP)*64
                        +(integer'(lane_base)+BYTE_IN_GROUP)*8 +: 8];
    end
  end endgenerate
endmodule
