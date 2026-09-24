// Eight 512x8 leaves, with a local four-by-four H1 butterfly.  A caller may
// assign the eight leaves to four pair positions times two adjacent bytes.
// The phase chain is reset to the aligned state (phase_i=0), so a composed
// array does not need 8*N startup cycles before its first legal request.
module edge_sram_h1_tile4k (
  input wire clk, rst_b, phase_i,
  output wire phase_o,
  input wire [7:0] req_valid_i, req_write_i, req_wstrb_i,
  input wire [71:0] req_addr_i,
  input wire [63:0] req_wdata_i,
  output wire [7:0] rsp_valid_o,
  output wire [63:0] rsp_data_o
);
  wire [8:0] phase_link;
  assign phase_link[0] = phase_i;
  assign phase_o = phase_link[8];
  genvar h;
  generate for (h=0; h<8; h=h+1) begin: HOP
    reg phase_q;
    always @(posedge clk or negedge rst_b)
      if (!rst_b) phase_q <= 1'b0;
      else phase_q <= ~phase_link[h];
    assign phase_link[h+1] = phase_q;
  end endgenerate
  wire swap = phase_link[4];
  wire [7:0] door_valid = swap ? {req_valid_i[3:0],req_valid_i[7:4]} : req_valid_i;
  wire [7:0] door_write = swap ? {req_write_i[3:0],req_write_i[7:4]} : req_write_i;
  wire [7:0] door_strb = swap ? {req_wstrb_i[3:0],req_wstrb_i[7:4]} : req_wstrb_i;
  wire [71:0] door_addr = swap ? {req_addr_i[35:0],req_addr_i[71:36]} : req_addr_i;
  wire [63:0] door_data = swap ? {req_wdata_i[31:0],req_wdata_i[63:32]} : req_wdata_i;
  reg [7:0] cmd_valid_q, cmd_write_q, cmd_strb_q;
  reg [71:0] cmd_addr_q;
  reg [63:0] cmd_data_q;
  reg swap_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) cmd_valid_q <= 8'b0;
    else cmd_valid_q <= door_valid;
  always @(posedge clk) begin
    cmd_write_q <= door_write;
    cmd_strb_q <= door_strb;
    cmd_addr_q <= door_addr;
    cmd_data_q <= door_data;
    swap_q <= swap;
  end
  wire [63:0] ram_data;
  genvar lane;
  generate for (lane=0; lane<8; lane=lane+1) begin: SRAM
    fakeram_512x8 x_macro (
      .clk(clk), .ce_in(cmd_valid_q[lane]),
      .we_in(cmd_valid_q[lane] && cmd_write_q[lane] && cmd_strb_q[lane]),
      .addr_in(cmd_addr_q[lane*9 +: 9]),
      .wd_in(cmd_data_q[lane*8 +: 8]),
      .rd_out(ram_data[lane*8 +: 8]));
  end endgenerate
  reg [7:0] ram_rsp_valid_q;
  reg rsp_swap_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) ram_rsp_valid_q <= 8'b0;
    else ram_rsp_valid_q <= cmd_valid_q & ~cmd_write_q;
  always @(posedge clk) rsp_swap_q <= swap_q;
  assign rsp_valid_o = rsp_swap_q ? {ram_rsp_valid_q[3:0],ram_rsp_valid_q[7:4]}
                                  : ram_rsp_valid_q;
  assign rsp_data_o = rsp_swap_q ? {ram_data[31:0],ram_data[63:32]} : ram_data;
endmodule
