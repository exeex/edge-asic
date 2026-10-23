// Width-aware packed WLD injection into a grid of local north/west relay stops.
module edge_wld_relay_router #(
  parameter DOTS=8, parameter INDEX_BITS=$clog2(DOTS)
)(
  input wire clk, input wire rst_b,
  input wire start_i, output wire start_ready_o, input wire [2:0] mode_i,
  input wire load_valid_i, output wire load_ready_o,
  input wire [DOTS*16-1:0] load_data_i,
  input wire advance_i, output wire busy_o, output reg done_o,
  output wire [DOTS*DOTS-1:0] take_valid_o,
  output wire [DOTS*DOTS*16-1:0] take_data_o,
  output wire [1:0] width_code_o
);
reg busy_q, load_complete_q;
reg [2:0] mode_q;
reg [INDEX_BITS-1:0] beat_q;
wire load_fire=load_valid_i && load_ready_o;
wire [INDEX_BITS:0] beat_limit=(INDEX_BITS+1)'(DOTS) >> mode_q[2:1];
wire [INDEX_BITS-1:0] row_base=beat_q << mode_q[2:1];
wire [DOTS*DOTS-1:0] relay_valid;
wire [15:0] relay_data [0:DOTS*DOTS-1];
wire [INDEX_BITS-1:0] relay_base [0:DOTS*DOTS-1];
wire [15:0] injection [0:DOTS-1];
assign start_ready_o=!busy_q;
assign busy_o=busy_q;
assign load_ready_o=busy_q && !load_complete_q && advance_i;
assign width_code_o=mode_q[2:1];
genvar lane, row, col;
generate
  for (lane=0;lane<DOTS;lane=lane+1) begin : GEN_INJECTION
    // Gather packed rows of one column. No numerical conversion or full-tile
    // transpose storage: this is a fixed width-selected 16-bit lane wiring.
    assign injection[lane]=mode_q[2:1]==0 ? load_data_i[lane*16 +: 16]
      : mode_q[2:1]==1 ? {load_data_i[(DOTS+lane)*8 +: 8],load_data_i[lane*8 +: 8]}
      : {load_data_i[(3*DOTS+lane)*4 +: 4],load_data_i[(2*DOTS+lane)*4 +: 4],
         load_data_i[(DOTS+lane)*4 +: 4],load_data_i[lane*4 +: 4]};
  end
  for (row=0;row<DOTS;row=row+1) begin : GEN_ROW
    for (col=0;col<DOTS;col=col+1) begin : GEN_COL
      localparam CELL=row*DOTS+col;
      wire north_valid, west_valid;
      wire [15:0] north_data, west_data;
      wire [INDEX_BITS-1:0] north_base, west_base;
      if (row==0) begin : GEN_NORTH_EDGE
        assign north_valid=load_fire;
        assign north_data=injection[col]; assign north_base=row_base;
      end else begin : GEN_NORTH_HOP
        assign north_valid=relay_valid[CELL-DOTS];
        assign north_data=relay_data[CELL-DOTS]; assign north_base=relay_base[CELL-DOTS];
      end
      if (col==0) begin : GEN_WEST_EDGE
        assign west_valid=load_fire;
        assign west_data=injection[row]; assign west_base=row_base;
      end else begin : GEN_WEST_HOP
        assign west_valid=relay_valid[CELL-1];
        assign west_data=relay_data[CELL-1]; assign west_base=relay_base[CELL-1];
      end
      edge_wld_relay_cell #(.ROW(row),.COL(col),.INDEX_BITS(INDEX_BITS)) ingress (
        .clk(clk),.rst_b(rst_b),.advance_i(advance_i),
        .transpose_i(mode_q[0]),.width_code_i(mode_q[2:1]),
        .north_valid_i(north_valid),.north_data_i(north_data),.north_base_i(north_base),
        .west_valid_i(west_valid),.west_data_i(west_data),.west_base_i(west_base),
        .relay_valid_o(relay_valid[CELL]),.relay_data_o(relay_data[CELL]),
        .relay_base_o(relay_base[CELL]),
        .take_valid_o(take_valid_o[CELL]),.take_data_o(take_data_o[CELL*16 +: 16])
      );
    end
  end
endgenerate
always @(posedge clk or negedge rst_b) begin
  if (!rst_b) begin busy_q<=0;load_complete_q<=0;mode_q<=0;beat_q<=0;done_o<=0;end
  else begin
    done_o<=0;
    if (start_i && start_ready_o) begin
      busy_q<=1;load_complete_q<=0;mode_q<=mode_i;beat_q<=0;
    end else if (busy_q) begin
      if (load_fire) begin
        beat_q<=beat_q+1'b1;
        if ({1'b0,beat_q}==beat_limit-1'b1) load_complete_q<=1;
      end
      // The final destination write has clocked before every relay valid is
      // clear. An input tail alone is never sufficient to publish completion.
      if (load_complete_q && !(|relay_valid)) begin busy_q<=0;done_o<=1;end
    end
  end
end
`ifndef SYNTHESIS
initial if (DOTS!=8 && DOTS!=16) $fatal(1,"WLD relay DOTS must be 8 or 16");
always @(posedge clk)
  if (rst_b && start_i && start_ready_o && mode_i>5) $fatal(1,"WLD relay invalid mode");
`endif
endmodule
