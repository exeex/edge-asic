// Assemble sparse packed dot fills into the legacy one-element-per-dot stream.
// Numeric conversion belongs to the consumer; narrow elements are zero-extended.
module edge_wld_packed_vectors #(
  parameter DOTS=16,
  parameter LANES=DOTS/2,
  parameter DOT_BITS=$clog2(DOTS),
  parameter SLOT_BITS=$clog2(DOTS/2)
)(
  input wire clk, input wire rst_b,
  input wire start_i, output wire start_ready_o, input wire [2:0] mode_i,
  input wire load_valid_i, output wire load_ready_o,
  input wire [DOTS*16-1:0] load_data_i, input wire load_last_i,
  output wire drain_valid_o, input wire drain_ready_i,
  output reg [DOTS*16-1:0] drain_data_o, output wire drain_last_o,
  output wire busy_o, output reg done_o
);
localparam IDLE=2'd0, LOAD=2'd1, DRAIN=2'd2;
reg [1:0] state_q;
reg [2:0] mode_q;
reg [DOT_BITS-1:0] load_count_q, drain_index_q;
// This is an interface assembly buffer, never a second numerical weight bank.
reg [DOTS*16-1:0] dot_words [0:DOTS-1];
wire router_ready, router_done;
wire [LANES-1:0] lane_valid;
wire [DOTS*16-1:0] lane_data;
wire [LANES*DOT_BITS-1:0] lane_dot;
wire [LANES*SLOT_BITS-1:0] lane_slot;
wire start_fire=start_i && start_ready_o;
wire [DOT_BITS:0] beat_limit=DOTS >> mode_q[2:1];
integer dot;
reg [15:0] element;
assign start_ready_o=state_q==IDLE && router_ready;
assign busy_o=state_q!=IDLE;
assign drain_valid_o=state_q==DRAIN;
assign drain_last_o=drain_valid_o && drain_index_q==DOT_BITS'(DOTS-1);
edge_wld_packed_router #(.DOTS(DOTS)) router (
  .clk(clk),.rst_b(rst_b),.start_i(start_fire),.start_ready_o(router_ready),
  .mode_i(mode_i),.busy_o(),.done_o(router_done),
  .load_valid_i(load_valid_i),.load_ready_o(load_ready_o),.load_data_i(load_data_i),
  .drain_valid_o(lane_valid),.drain_ready_i({LANES{1'b1}}),
  .drain_data_o(lane_data),.drain_target_dot_o(lane_dot),.drain_fill_slot_o(lane_slot)
);
// Decode sparse destination once per dot. The router guarantees at most one
// valid lane per dot, so a parallel masked OR replaces a multiwrite tile RAM.
// Constant dot/slot destinations avoid a wide variable-address write crossbar.
genvar dot_g, slot_g;
generate for (dot_g=0;dot_g<DOTS;dot_g=dot_g+1) begin : GEN_DOT
  reg [31:0] fill_data;
  reg [LANES-1:0] fill_slot;
  integer fill_lane;
  always @* begin
    fill_data=0; fill_slot=0;
    for (fill_lane=0;fill_lane<LANES;fill_lane=fill_lane+1) begin
      if (lane_valid[fill_lane] && lane_dot[fill_lane*DOT_BITS +: DOT_BITS]==DOT_BITS'(dot_g)) begin
        fill_data=fill_data | lane_data[fill_lane*32 +: 32];
        fill_slot=fill_slot | ({{(LANES-1){1'b0}},1'b1} << lane_slot[fill_lane*SLOT_BITS +: SLOT_BITS]);
      end
    end
  end
  for (slot_g=0;slot_g<LANES;slot_g=slot_g+1) begin : GEN_WORD
    always @(posedge clk)
      if (fill_slot[slot_g]) dot_words[dot_g][slot_g*32 +: 32]<=fill_data;
  end
end endgenerate
always @* begin
  drain_data_o=0;
  for (dot=0;dot<DOTS;dot=dot+1) begin
    case (mode_q[2:1])
      0: element=dot_words[dot][drain_index_q*16 +: 16];
      1: element={8'b0,dot_words[dot][drain_index_q*8 +: 8]};
      default: element={12'b0,dot_words[dot][drain_index_q*4 +: 4]};
    endcase
    drain_data_o[dot*16 +: 16]=element;
  end
end
always @(posedge clk or negedge rst_b) begin
  if (!rst_b) begin
    state_q<=IDLE; mode_q<=0; load_count_q<=0; drain_index_q<=0; done_o<=0;
  end else begin
    done_o<=0;
    if (start_fire) begin
      state_q<=LOAD; mode_q<=mode_i; load_count_q<=0; drain_index_q<=0;
    end
    if (load_valid_i && load_ready_o) load_count_q<=load_count_q+1'b1;
    if (state_q==LOAD && router_done) state_q<=DRAIN;
    if (drain_valid_o && drain_ready_i) begin
      if (drain_last_o) begin state_q<=IDLE; done_o<=1; end
      else drain_index_q<=drain_index_q+1'b1;
    end
  end
end
`ifndef SYNTHESIS
always @(posedge clk) begin
  if (rst_b && load_valid_i && load_ready_o
      && load_last_i != ((DOT_BITS+1)'(load_count_q)==beat_limit-1))
    $fatal(1,"WLD malformed packed vector tail");
end
`endif
endmodule
