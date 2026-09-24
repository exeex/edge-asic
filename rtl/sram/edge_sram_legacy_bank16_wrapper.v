// Raw-interface compatibility shell for one legacy 128 KiB bank16 slice.
// Split pair bit 0 across two 64 KiB fragments; pair bits 2:1 become each
// fragment's four local 128-bit pair positions.  Two product slices therefore
// compose four fragments without changing byte-address mapping or capacity.
// This shell is for A/B substitution; it does not own client-side queues.
module edge_sram_legacy_bank16_wrapper #(
  parameter ADDR_WIDTH=18,
  parameter SRAM_ADDR_WIDTH=10,
  parameter DATA_WIDTH=64,
  parameter ROUTE_COUNT=4
)(
  input wire clk, rst_b,
  output wire [2:0] local_phase_o,
  input wire [3:0] upper_req_valid_i, upper_req_write_i,
  input wire [4*ADDR_WIDTH-1:0] upper_req_addr_i,
  input wire [511:0] upper_req_wdata_i,
  input wire [63:0] upper_req_wstrb_i,
  output wire [3:0] upper_rsp_valid_o,
  output wire [511:0] upper_rsp_data_o,
  input wire [3:0] lower_req_valid_i, lower_req_write_i,
  input wire [4*ADDR_WIDTH-1:0] lower_req_addr_i,
  input wire [511:0] lower_req_wdata_i,
  input wire [63:0] lower_req_wstrb_i,
  output wire [3:0] lower_rsp_valid_o,
  output wire [511:0] lower_rsp_data_o
);
  reg [2:0] phase_q;
  assign local_phase_o = phase_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) phase_q <= 3'b0;
    else phase_q <= phase_q + 3'd1;

  // Compatibility H4 cut: select the addressed physical pair from the eight
  // legal time-triggered routes.  Under the window contract the eight pairs
  // are distinct each cycle, so this is a permutation, not arbitration.
  reg [7:0] pair_valid_c, pair_write_c;
  reg [79:0] pair_addr_c;
  reg [1023:0] pair_wdata_c;
  reg [127:0] pair_wstrb_c;
  reg [2:0] pair_index;
  integer slot;
  always @* begin
    pair_valid_c=0; pair_write_c=0; pair_addr_c=0;
    pair_wdata_c=0; pair_wstrb_c=0;
    pair_index=0; slot=0;
    for (integer r=0; r<4; r=r+1) begin
      if (upper_req_valid_i[r]) begin
        pair_index=upper_req_addr_i[r*ADDR_WIDTH+5 +: 3];
        slot=integer'(pair_index[0])*4+integer'(pair_index[2:1]);
        pair_valid_c[slot]=1'b1;
        pair_write_c[slot]=upper_req_write_i[r];
        pair_addr_c[slot*10 +: 10]=upper_req_addr_i[r*ADDR_WIDTH+8 +: 10];
        pair_wdata_c[slot*128 +: 128]=upper_req_wdata_i[r*128 +: 128];
        pair_wstrb_c[slot*16 +: 16]=upper_req_wstrb_i[r*16 +: 16];
      end
      if (lower_req_valid_i[r]) begin
        pair_index=lower_req_addr_i[r*ADDR_WIDTH+5 +: 3];
        slot=integer'(pair_index[0])*4+integer'(pair_index[2:1]);
        pair_valid_c[slot]=1'b1;
        pair_write_c[slot]=lower_req_write_i[r];
        pair_addr_c[slot*10 +: 10]=lower_req_addr_i[r*ADDR_WIDTH+8 +: 10];
        pair_wdata_c[slot*128 +: 128]=lower_req_wdata_i[r*128 +: 128];
        pair_wstrb_c[slot*16 +: 16]=lower_req_wstrb_i[r*16 +: 16];
      end
    end
  end
  reg [7:0] pair_valid_q, pair_write_q;
  reg [79:0] pair_addr_q;
  reg [1023:0] pair_wdata_q;
  reg [127:0] pair_wstrb_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) pair_valid_q <= 8'b0;
    else pair_valid_q <= pair_valid_c;
  always @(posedge clk) begin
    pair_write_q <= pair_write_c;
    pair_addr_q <= pair_addr_c;
    pair_wdata_q <= pair_wdata_c;
    pair_wstrb_q <= pair_wstrb_c;
  end
  wire [7:0] pair_rsp_valid;
  wire [1023:0] pair_rsp_data;
  wire [2:0] phase_tail;
  assign phase_tail[0] = phase_q[0];
  genvar m;
  generate for (m=0; m<2; m=m+1) begin: FRAGMENT
    edge_sram_quad64k x_quad (
      .clk(clk), .rst_b(rst_b),
      .phase_i(phase_tail[m]), .phase_o(phase_tail[m+1]),
      .pair_valid_i(pair_valid_q[m*4 +: 4]),
      .pair_write_i(pair_write_q[m*4 +: 4]),
      .pair_addr_i(pair_addr_q[m*40 +: 40]),
      .pair_wdata_i(pair_wdata_q[m*512 +: 512]),
      .pair_wstrb_i(pair_wstrb_q[m*64 +: 64]),
      .pair_rsp_valid_o(pair_rsp_valid[m*4 +: 4]),
      .pair_rsp_data_o(pair_rsp_data[m*512 +: 512]));
  end endgenerate

  reg [3:0] uv1_q, uv2_q, uv3_q, uv4_q;
  reg [3:0] lv1_q, lv2_q, lv3_q, lv4_q;
  reg [11:0] up1_q, up2_q, up3_q, up4_q;
  reg [11:0] lp1_q, lp2_q, lp3_q, lp4_q;
  assign upper_rsp_valid_o=uv4_q;
  assign lower_rsp_valid_o=lv4_q;
  always @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      uv1_q<=0; uv2_q<=0; uv3_q<=0; uv4_q<=0;
      lv1_q<=0; lv2_q<=0; lv3_q<=0; lv4_q<=0;
    end else begin
      uv1_q<=upper_req_valid_i & ~upper_req_write_i;
      uv2_q<=uv1_q; uv3_q<=uv2_q; uv4_q<=uv3_q;
      lv1_q<=lower_req_valid_i & ~lower_req_write_i;
      lv2_q<=lv1_q; lv3_q<=lv2_q; lv4_q<=lv3_q;
    end
  end
  always @(posedge clk) begin
    for (integer r=0; r<4; r=r+1) begin
      up1_q[r*3 +: 3] <= upper_req_addr_i[r*ADDR_WIDTH+5 +: 3];
      lp1_q[r*3 +: 3] <= lower_req_addr_i[r*ADDR_WIDTH+5 +: 3];
    end
    up2_q<=up1_q; up3_q<=up2_q; up4_q<=up3_q;
    lp2_q<=lp1_q; lp3_q<=lp2_q; lp4_q<=lp3_q;
  end
  genvar route;
  generate for (route=0; route<4; route=route+1) begin: RESPONSE
    wire [2:0] up_pair=up4_q[route*3 +: 3];
    wire [2:0] lo_pair=lp4_q[route*3 +: 3];
    wire [2:0] up_slot={up_pair[0],up_pair[2:1]};
    wire [2:0] lo_slot={lo_pair[0],lo_pair[2:1]};
    assign upper_rsp_data_o[route*128 +: 128]=
        pair_rsp_data[up_slot*128 +: 128];
    assign lower_rsp_data_o[route*128 +: 128]=
        pair_rsp_data[lo_slot*128 +: 128];
  end endgenerate
`ifndef SYNTHESIS
  initial if (ADDR_WIDTH != 18 || SRAM_ADDR_WIDTH != 10
              || DATA_WIDTH != 64 || ROUTE_COUNT != 4)
    $fatal(1,"SRAM compatibility wrapper requires 18/10/64/4 shape");
  always @(posedge clk) if (rst_b) begin
    for (integer r=0; r<4; r=r+1) begin
      if (upper_req_valid_i[r] &&
          upper_req_addr_i[r*ADDR_WIDTH+5 +: 3]
              != (3'(2*r+1)+phase_q))
        $fatal(1,"SRAM upper raw route %0d missed pair window",r);
      if (lower_req_valid_i[r] &&
          lower_req_addr_i[r*ADDR_WIDTH+5 +: 3]
              != (3'(2*r)+phase_q))
        $fatal(1,"SRAM lower raw route %0d missed pair window",r);
    end
  end
`endif
endmodule
