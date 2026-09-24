// One two-byte group across both 512-row depth halves: 16 x 512x8.
// Each row keeps the original independent four-by-four H1 butterfly.  Bit 9
// selects the row locally; bits 8:0 are the only SRAM address pins.
module edge_sram_h1_tile8k (
  input wire clk, rst_b, phase_i,
  output wire phase_o,
  input wire [7:0] req_valid_i, req_write_i, req_wstrb_i,
  input wire [79:0] req_addr_i,
  input wire [63:0] req_wdata_i,
  output wire [7:0] rsp_valid_o,
  output wire [63:0] rsp_data_o
);
  wire [2:0] phase_link;
  assign phase_link[0] = phase_i;
  assign phase_o = phase_link[2];
  wire [7:0] row_rsp_valid [0:1];
  wire [63:0] row_rsp_data [0:1];
  wire [7:0] depth_select;
  genvar lane, depth;
  generate for (lane=0; lane<8; lane=lane+1) begin: LANE
    assign depth_select[lane] = req_addr_i[lane*10+9];
  end
  for (depth=0; depth<2; depth=depth+1) begin: DEPTH
    wire [7:0] row_valid;
    wire [71:0] row_addr;
    for (lane=0; lane<8; lane=lane+1) begin: INPUT_LANE
      assign row_valid[lane] = req_valid_i[lane]
                                  && (depth_select[lane] == 1'(depth));
      assign row_addr[lane*9 +: 9] = req_addr_i[lane*10 +: 9];
    end
    edge_sram_h1_tile4k x_row (
      .clk(clk), .rst_b(rst_b), .phase_i(phase_link[depth]),
      .phase_o(phase_link[depth+1]),
      .req_valid_i(row_valid), .req_write_i(req_write_i),
      .req_wstrb_i(req_wstrb_i), .req_addr_i(row_addr),
      .req_wdata_i(req_wdata_i),
      .rsp_valid_o(row_rsp_valid[depth]),
      .rsp_data_o(row_rsp_data[depth]));
  end endgenerate

  // The 4 KiB H1 command cut and synchronous SRAM read take two clocks from
  // this boundary.  Only valid needs reset; an invalid response ignores data.
  reg [7:0] depth_d1_q, depth_d2_q;
  always @(posedge clk) begin
    depth_d1_q <= depth_select;
    depth_d2_q <= depth_d1_q;
  end
  generate for (lane=0; lane<8; lane=lane+1) begin: RESPONSE_LANE
    assign rsp_valid_o[lane] = row_rsp_valid[0][lane]
                                | row_rsp_valid[1][lane];
    assign rsp_data_o[lane*8 +: 8] = depth_d2_q[lane]
        ? row_rsp_data[1][lane*8 +: 8]
        : row_rsp_data[0][lane*8 +: 8];
  end endgenerate
endmodule
