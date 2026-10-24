// 32 KiB H1: two 1024x128 physical pairs, 64 independent 512x8 SRAMs.
// Canonical alternating phase swaps the two logical 128b ports at each byte.
// SRAM is the sole payload register; valid/depth/phase tags follow that edge.
module edge_sram_h1_tile32k (
  input wire clk, rst_b, phase_i,
  output wire phase_o, ready_o,
  input wire [1:0] req_valid_i, req_write_i,
  input wire [19:0] req_addr_i,
  input wire [255:0] req_wdata_i,
  input wire [31:0] req_wstrb_i,
  output wire [1:0] rsp_valid_o,
  output wire [255:0] rsp_data_o
);
  wire [32:0] phase_link;
  assign phase_link[0]=phase_i;
  assign phase_o=phase_link[32];
  reg [5:0] fill_q;
  always @(posedge clk or negedge rst_b)
    if(!rst_b) fill_q<=0;
    else if(fill_q!=32) fill_q<=fill_q+1'b1;
  assign ready_o=(fill_q==32);
  reg [1:0] valid_q;
  always @(posedge clk or negedge rst_b)
    if(!rst_b) valid_q<=0;
    else valid_q<=req_valid_i & ~req_write_i & {2{ready_o}};
  assign rsp_valid_o=valid_q;
  genvar h,b,p,d;
  generate for(h=0;h<32;h=h+1) begin: HOP
    reg phase_q;
    always @(posedge clk or negedge rst_b)
      if(!rst_b) phase_q<=0;
      else phase_q<=~phase_link[h];
    assign phase_link[h+1]=phase_q;
  end
  for(b=0;b<16;b=b+1) begin: BYTE
    wire swap=phase_link[2*b];
    reg swap_q;
    always @(posedge clk) swap_q<=swap;
    wire [15:0] physical_data;
    for(p=0;p<2;p=p+1) begin: PAIR
      wire source=1'(p)^swap;
      wire [9:0] address=req_addr_i[source*10+:10];
      wire selected=ready_o && rst_b && req_valid_i[source];
      wire write_en=req_write_i[source] && req_wstrb_i[source*16+b];
      reg depth_q;
      always @(posedge clk) depth_q<=address[9];
      wire [15:0] depth_data;
      for(d=0;d<2;d=d+1) begin: DEPTH
        fakeram_512x8 x_sram (
          .clk(clk), .ce_in(selected && address[9]==1'(d)),
          .we_in(selected && address[9]==1'(d) && write_en),
          .addr_in(address[8:0]), .wd_in(req_wdata_i[source*128+b*8+:8]),
          .rd_out(depth_data[d*8+:8]));
      end
      assign physical_data[p*8+:8]=depth_data[depth_q*8+:8];
    end
    assign rsp_data_o[b*8+:8]=physical_data[swap_q*8+:8];
    assign rsp_data_o[128+b*8+:8]=physical_data[(1'b1^swap_q)*8+:8];
`ifndef SYNTHESIS
    always @(posedge clk) if(rst_b && ready_o && swap!==phase_i)
      $fatal(1,"H1 byte phase not aligned");
`endif
  end endgenerate
`ifndef SYNTHESIS
  always @(posedge clk) if(rst_b && ready_o && phase_o!==phase_i)
    $fatal(1,"H1 phase tail not aligned");
`endif
endmodule
