// 64 KiB compatibility fragment: two independent 32 KiB depth halves.
// Address bit 9 selects the half here; each half exposes all 64 physical
// 512x8 leaves without a deeper merge.  The input register preserves the
// legacy H2 timing cut, while the outer wrapper owns H4 and rotation.
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

  wire [2:0] phase_link;
  assign phase_link[0] = phase_i;
  assign phase_o = phase_link[2];
  wire [3:0] depth_rsp_valid [0:1];
  wire [511:0] depth_rsp_data [0:1];
  genvar depth, pair;
  generate for (depth=0; depth<2; depth=depth+1) begin: DEPTH
    wire [3:0] row_valid;
    wire [35:0] row_addr;
    for (pair=0; pair<4; pair=pair+1) begin: PAIR
      assign row_valid[pair] = pair_valid_q[pair]
          && (pair_addr_q[pair*10+9] == 1'(depth));
      assign row_addr[pair*9 +: 9] = pair_addr_q[pair*10 +: 9];
    end
    edge_sram_h1_array32k x_array (
      .clk(clk), .rst_b(rst_b),
      .phase_i(phase_link[depth]), .phase_o(phase_link[depth+1]),
      .pair_valid_i(row_valid), .pair_write_i(pair_write_q),
      .pair_addr_i(row_addr), .pair_wdata_i(pair_wdata_q),
      .pair_wstrb_i(pair_wstrb_q),
      .pair_rsp_valid_o(depth_rsp_valid[depth]),
      .pair_rsp_data_o(depth_rsp_data[depth]));
  end endgenerate

  // The row choice accompanies the H1 command register and SRAM read.
  reg [3:0] depth_d1_q, depth_d2_q;
  always @(posedge clk) begin
    for (integer p=0; p<4; p=p+1) begin
      depth_d1_q[p] <= pair_addr_q[p*10+9];
      depth_d2_q[p] <= depth_d1_q[p];
    end
  end
  generate for (pair=0; pair<4; pair=pair+1) begin: RESPONSE_PAIR
    assign pair_rsp_valid_o[pair] =
        depth_rsp_valid[0][pair] | depth_rsp_valid[1][pair];
    assign pair_rsp_data_o[pair*128 +: 128] = depth_d2_q[pair]
        ? depth_rsp_data[1][pair*128 +: 128]
        : depth_rsp_data[0][pair*128 +: 128];
  end endgenerate
endmodule
