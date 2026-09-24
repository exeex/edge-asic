// Functional raw-bank16 adapter: four 32 KiB H4 tiles replace one 128 KiB
// E4 DTCM slice.  Routing is decided here; no client-side queue is added.
// One extra registered cut precedes H4, so reads return five sampling edges
// after issue rather than the legacy four.
module edge_sram_h4_bank16_wrapper #(
  parameter ADDR_WIDTH = 18
)(
  input wire clk, rst_b,
  output wire [2:0] local_phase_o,
  output wire phase_ready_o,
  input wire [3:0] upper_req_valid_i, upper_req_write_i,
  input wire [4*ADDR_WIDTH-1:0] upper_req_addr_i,
  input wire [511:0] upper_req_wdata_i,
  input wire [63:0] upper_req_wstrb_i,
  output wire [3:0] upper_rsp_valid_o,
  output reg [511:0] upper_rsp_data_o,
  input wire [3:0] lower_req_valid_i, lower_req_write_i,
  input wire [4*ADDR_WIDTH-1:0] lower_req_addr_i,
  input wire [511:0] lower_req_wdata_i,
  input wire [63:0] lower_req_wstrb_i,
  output wire [3:0] lower_rsp_valid_o,
  output reg [511:0] lower_rsp_data_o
);
  reg [2:0] phase_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) phase_q <= 3'b0;
    else phase_q <= phase_q + 3'd1;
  assign local_phase_o = phase_q;

  // A chain through four 32 KiB tiles has 256 H1 hops.  H2/H4 each
  // require only 64 clocks, so the H1 tail determines wake-up fill.
  reg [8:0] fill_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) fill_q <= 9'd0;
    else if (fill_q != 9'd256) fill_q <= fill_q + 9'd1;
  assign phase_ready_o = (fill_q == 9'd256);

  // Wrapper register samples now.  H4, H2, H1 sample at the next three
  // edges respectively.  These lookaheads invert their phase butterflies
  // so a legacy physical pair/byte/depth keeps one permanent SRAM location.
  wire [2:0] phase_h4_at_cut = phase_q + 3'd1;
  wire [2:0] phase_h2_at_cut = phase_q + 3'd2;
  wire [2:0] phase_h1_at_cut = phase_q + 3'd3;

  reg [127:0] routed_valid_c, routed_write_c, routed_strb_c;
  reg [127:0] routed_half_c;
  reg [1151:0] routed_addr_c;
  reg [1023:0] routed_data_c;
  integer route, byte_i, pair_i, module_i, slot_i, lane_i;
  always @* begin
    routed_valid_c = 128'b0;
    routed_write_c = 128'b0;
    routed_strb_c = 128'b0;
    routed_half_c = 128'b0;
    routed_addr_c = 1152'b0;
    routed_data_c = 1024'b0;
    pair_i = 0; module_i = 0; slot_i = 0; lane_i = 0;
    for (route=0; route<4; route=route+1) begin
      if (upper_req_valid_i[route]) begin
        pair_i = int'(upper_req_addr_i[route*ADDR_WIDTH+5 +: 3]);
        module_i = pair_i / 2;
        slot_i = (pair_i % 2) ^ int'(phase_h4_at_cut[2]);
        for (byte_i=0; byte_i<16; byte_i=byte_i+1) begin
          lane_i = module_i*32 + slot_i*16 + (byte_i/8)*8
              + (((byte_i/4)%2) ^ int'(phase_h2_at_cut[1]))*4
              + (byte_i%4);
          routed_valid_c[lane_i] = 1'b1;
          routed_write_c[lane_i] = upper_req_write_i[route];
          routed_strb_c[lane_i] = upper_req_wstrb_i[route*16+byte_i];
          routed_half_c[lane_i] =
              upper_req_addr_i[route*ADDR_WIDTH+17] ^ phase_h1_at_cut[0];
          routed_addr_c[lane_i*9 +: 9] =
              upper_req_addr_i[route*ADDR_WIDTH+8 +: 9];
          routed_data_c[lane_i*8 +: 8] =
              upper_req_wdata_i[route*128+byte_i*8 +: 8];
        end
      end
      if (lower_req_valid_i[route]) begin
        pair_i = int'(lower_req_addr_i[route*ADDR_WIDTH+5 +: 3]);
        module_i = pair_i / 2;
        slot_i = (pair_i % 2) ^ int'(phase_h4_at_cut[2]);
        for (byte_i=0; byte_i<16; byte_i=byte_i+1) begin
          lane_i = module_i*32 + slot_i*16 + (byte_i/8)*8
              + (((byte_i/4)%2) ^ int'(phase_h2_at_cut[1]))*4
              + (byte_i%4);
          routed_valid_c[lane_i] = 1'b1;
          routed_write_c[lane_i] = lower_req_write_i[route];
          routed_strb_c[lane_i] = lower_req_wstrb_i[route*16+byte_i];
          routed_half_c[lane_i] =
              lower_req_addr_i[route*ADDR_WIDTH+17] ^ phase_h1_at_cut[0];
          routed_addr_c[lane_i*9 +: 9] =
              lower_req_addr_i[route*ADDR_WIDTH+8 +: 9];
          routed_data_c[lane_i*8 +: 8] =
              lower_req_wdata_i[route*128+byte_i*8 +: 8];
        end
      end
    end
  end

  reg [127:0] routed_valid_q, routed_write_q, routed_strb_q;
  reg [127:0] routed_half_q;
  reg [1151:0] routed_addr_q;
  reg [1023:0] routed_data_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) routed_valid_q <= 128'b0;
    else routed_valid_q <= {128{phase_ready_o}} & routed_valid_c;
  always @(posedge clk) begin
    routed_write_q <= routed_write_c;
    routed_strb_q <= routed_strb_c;
    routed_half_q <= routed_half_c;
    routed_addr_q <= routed_addr_c;
    routed_data_q <= routed_data_c;
  end

  wire [4:0] h1_link, h2_link, h4_link;
  wire [127:0] tile_rsp_valid;
  wire [1023:0] tile_rsp_data;
  wire [3:0] tile_ready;
  assign h1_link[0] = phase_q[0];
  assign h2_link[0] = phase_q[1];
  assign h4_link[0] = phase_q[2];
  genvar module_no;
  generate for (module_no=0; module_no<4; module_no=module_no+1) begin: MODULE
    edge_sram_h4_tile32k x_tile (
      .clk(clk), .rst_b(rst_b),
      .phase_h1_i(h1_link[module_no]),
      .phase_h2_i(h2_link[module_no]),
      .phase_h4_i(h4_link[module_no]),
      .phase_h1_o(h1_link[module_no+1]),
      .phase_h2_o(h2_link[module_no+1]),
      .phase_h4_o(h4_link[module_no+1]),
      .phase_ready_o(tile_ready[module_no]),
      .req_valid_i(routed_valid_q[module_no*32 +: 32]),
      .req_write_i(routed_write_q[module_no*32 +: 32]),
      .req_wstrb_i(routed_strb_q[module_no*32 +: 32]),
      .req_bank_half_i(routed_half_q[module_no*32 +: 32]),
      .req_addr_i(routed_addr_q[module_no*288 +: 288]),
      .req_wdata_i(routed_data_q[module_no*256 +: 256]),
      .rsp_valid_o(tile_rsp_valid[module_no*32 +: 32]),
      .rsp_data_o(tile_rsp_data[module_no*256 +: 256]));
  end endgenerate

  // Original routes receive their bytes in their original order.  The tag
  // follows the wrapper/H4/H2/H1/SRAM five-edge request pipeline.
  reg [3:0] upper_read_tag [0:4], lower_read_tag [0:4];
  reg [11:0] upper_pair_tag [0:4], lower_pair_tag [0:4];
  reg [4:0] h4_tag, h2_tag;
  always @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      for (integer s=0; s<5; s=s+1) begin
        upper_read_tag[s] <= 4'b0;
        lower_read_tag[s] <= 4'b0;
      end
    end else begin
      upper_read_tag[0] <= {4{phase_ready_o}} &
          upper_req_valid_i & ~upper_req_write_i;
      lower_read_tag[0] <= {4{phase_ready_o}} &
          lower_req_valid_i & ~lower_req_write_i;
      for (integer s=1; s<5; s=s+1) begin
        upper_read_tag[s] <= upper_read_tag[s-1];
        lower_read_tag[s] <= lower_read_tag[s-1];
      end
    end
  end
  always @(posedge clk) begin
    for (integer r=0; r<4; r=r+1) begin
      upper_pair_tag[0][r*3 +: 3] <=
          upper_req_addr_i[r*ADDR_WIDTH+5 +: 3];
      lower_pair_tag[0][r*3 +: 3] <=
          lower_req_addr_i[r*ADDR_WIDTH+5 +: 3];
    end
    h4_tag[0] <= phase_h4_at_cut[2];
    h2_tag[0] <= phase_h2_at_cut[1];
    for (integer s=1; s<5; s=s+1) begin
      upper_pair_tag[s] <= upper_pair_tag[s-1];
      lower_pair_tag[s] <= lower_pair_tag[s-1];
      h4_tag[s] <= h4_tag[s-1];
      h2_tag[s] <= h2_tag[s-1];
    end
  end
  reg [3:0] upper_bytes_valid, lower_bytes_valid;
  assign upper_rsp_valid_o = upper_read_tag[4] & upper_bytes_valid;
  assign lower_rsp_valid_o = lower_read_tag[4] & lower_bytes_valid;

  integer out_route, out_byte, out_pair, out_lane;
  always @* begin
    upper_rsp_data_o = 512'b0;
    lower_rsp_data_o = 512'b0;
    upper_bytes_valid = 4'hf;
    lower_bytes_valid = 4'hf;
    out_pair = 0; out_lane = 0;
    for (out_route=0; out_route<4; out_route=out_route+1) begin
      out_pair = int'(upper_pair_tag[4][out_route*3 +: 3]);
      for (out_byte=0; out_byte<16; out_byte=out_byte+1) begin
        out_lane = (out_pair/2)*32
            + ((out_pair%2) ^ int'(h4_tag[4]))*16
            + (out_byte/8)*8
            + (((out_byte/4)%2) ^ int'(h2_tag[4]))*4
            + (out_byte%4);
        upper_rsp_data_o[out_route*128+out_byte*8 +: 8] =
            tile_rsp_data[out_lane*8 +: 8];
        upper_bytes_valid[out_route] = upper_bytes_valid[out_route] &
            tile_rsp_valid[out_lane];
      end
      out_pair = int'(lower_pair_tag[4][out_route*3 +: 3]);
      for (out_byte=0; out_byte<16; out_byte=out_byte+1) begin
        out_lane = (out_pair/2)*32
            + ((out_pair%2) ^ int'(h4_tag[4]))*16
            + (out_byte/8)*8
            + (((out_byte/4)%2) ^ int'(h2_tag[4]))*4
            + (out_byte%4);
        lower_rsp_data_o[out_route*128+out_byte*8 +: 8] =
            tile_rsp_data[out_lane*8 +: 8];
        lower_bytes_valid[out_route] = lower_bytes_valid[out_route] &
            tile_rsp_valid[out_lane];
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_b && phase_ready_o) begin
    if (h1_link[4] !== phase_q[0] ||
        h2_link[4] !== phase_q[1] ||
        h4_link[4] !== phase_q[2])
      $fatal(1, "SRAM wrapper phase tails differ after fill");
    if (tile_ready !== 4'hf)
      $fatal(1, "SRAM wrapper tile not ready after fill");
    for (integer r=0; r<4; r=r+1) begin
      if (upper_req_valid_i[r] &&
          upper_req_addr_i[r*ADDR_WIDTH+5 +: 3] !==
          (3'(2*r+1)+phase_q))
        $fatal(1, "SRAM wrapper upper route outside phase window");
      if (lower_req_valid_i[r] &&
          lower_req_addr_i[r*ADDR_WIDTH+5 +: 3] !==
          (3'(2*r)+phase_q))
        $fatal(1, "SRAM wrapper lower route outside phase window");
    end
  end
`endif
endmodule
