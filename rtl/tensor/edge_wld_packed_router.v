// Packed, numeric-format-independent WLD routing. Mode is {width_code, transpose}.
module edge_wld_packed_router #(
  parameter DOTS = 8,
  parameter DOT_BITS = $clog2(DOTS),
  parameter LANES = DOTS/2,
  parameter SLOT_BITS = $clog2(DOTS/2),
  parameter DEPTH = DOTS/2,
  parameter PTR_BITS = $clog2(DEPTH)
)(
  clk, rst_b, start_i, start_ready_o, mode_i, busy_o, done_o,
  load_valid_i, load_ready_o, load_data_i,
  drain_valid_o, drain_ready_i, drain_data_o,
  drain_target_dot_o, drain_fill_slot_o
);
input clk, rst_b, start_i;
output start_ready_o, busy_o, done_o;
input [2:0] mode_i;
input load_valid_i;
output load_ready_o;
input [DOTS*16-1:0] load_data_i;
output [LANES-1:0] drain_valid_o;
input [LANES-1:0] drain_ready_i;
output [DOTS*16-1:0] drain_data_o;
output [LANES*DOT_BITS-1:0] drain_target_dot_o;
output [LANES*SLOT_BITS-1:0] drain_fill_slot_o;

localparam MODE_N16=3'd0, MODE_T16=3'd1;
localparam MODE_N8 =3'd2, MODE_T8 =3'd3;
localparam MODE_N4 =3'd4, MODE_T4 =3'd5;

reg busy_q, done_q, load_complete_q, trans_half_q;
reg [2:0] mode_q;
reg [DOT_BITS-1:0] load_count_q, trans_group_q;
reg [31:0] data_mem [0:LANES-1][0:DEPTH-1];
reg [DOT_BITS-1:0] dot_mem [0:LANES-1][0:DEPTH-1];
reg [SLOT_BITS-1:0] slot_mem [0:LANES-1][0:DEPTH-1];
reg [PTR_BITS-1:0] head_q [0:LANES-1], tail_q [0:LANES-1];
reg [PTR_BITS:0] count_q [0:LANES-1];
reg [LANES-1:0] select_comb;
reg [LANES-1:0] stalled_q;
reg [DOTS-1:0] used_dot_comb;
reg [DOT_BITS-1:0] head_dot;
wire [LANES-1:0] dequeue = select_comb & drain_ready_i;
wire transpose_mode = mode_q[0];
wire load_accept = load_valid_i && load_ready_o;
integer lane_i;

function [DOT_BITS:0] expected_beats;
  input [2:0] mode;
  begin
    case (mode)
      MODE_N16,MODE_T16: expected_beats=DOTS;
      MODE_N8, MODE_T8:  expected_beats=DOTS/2;
      default:            expected_beats=DOTS/4;
    endcase
  end
endfunction

function [31:0] transpose_chunk;
  input [2:0] mode;
  input [DOT_BITS-1:0] target;
  input [DOTS*16-1:0] beat0;
  input [DOTS*16-1:0] beat1;
  integer row;
  begin
    transpose_chunk=0;
    case (mode)
      MODE_T16:
        transpose_chunk={beat1[target*16 +: 16],beat0[target*16 +: 16]};
      MODE_T8: begin
        for (row=0;row<2;row=row+1) begin
          transpose_chunk[row*8 +: 8]=beat0[(row*DOTS+int'(target))*8 +: 8];
          transpose_chunk[(row+2)*8 +: 8]=beat1[(row*DOTS+int'(target))*8 +: 8];
        end
      end
      MODE_T4: begin
        for (row=0;row<4;row=row+1) begin
          transpose_chunk[row*4 +: 4]=beat0[(row*DOTS+int'(target))*4 +: 4];
          transpose_chunk[(row+4)*4 +: 4]=beat1[(row*DOTS+int'(target))*4 +: 4];
        end
      end
      default: transpose_chunk=0;
    endcase
  end
endfunction

wire [DOTS*16-1:0] trans_beat0;
genvar input_lane;
generate for (input_lane=0; input_lane<LANES; input_lane=input_lane+1) begin : GEN_SAVED_BEAT
  assign trans_beat0[input_lane*32 +: 32]=data_mem[input_lane][tail_q[input_lane]];
end endgenerate
wire [DOT_BITS:0] beat_limit = expected_beats(mode_q);
wire [2:0] enqueue_count = transpose_mode ? (trans_half_q ? 3'd2 : 3'd0)
                                          : 3'd1;

always @(*) begin
  select_comb=stalled_q;
  used_dot_comb=0;
  for (lane_i=0;lane_i<LANES;lane_i=lane_i+1)
    if (stalled_q[lane_i]) used_dot_comb[dot_mem[lane_i][head_q[lane_i]]]=1'b1;
  for (lane_i=0;lane_i<LANES;lane_i=lane_i+1) begin
    head_dot=dot_mem[lane_i][head_q[lane_i]];
    if (!stalled_q[lane_i] && count_q[lane_i] != 0 && !used_dot_comb[head_dot]) begin
      select_comb[lane_i]=1'b1;
      used_dot_comb[head_dot]=1'b1;
    end
  end
end

generate
  genvar lane_g;
  for (lane_g=0;lane_g<LANES;lane_g=lane_g+1) begin : GEN_DRAIN
    assign drain_valid_o[lane_g]=select_comb[lane_g];
    assign drain_data_o[lane_g*32 +: 32]=data_mem[lane_g][head_q[lane_g]];
    assign drain_target_dot_o[lane_g*DOT_BITS +: DOT_BITS]=dot_mem[lane_g][head_q[lane_g]];
    assign drain_fill_slot_o[lane_g*SLOT_BITS +: SLOT_BITS]=slot_mem[lane_g][head_q[lane_g]];
  end
endgenerate

assign start_ready_o=!busy_q;
assign busy_o=busy_q;
assign done_o=done_q;
reg lanes_have_space, lanes_empty_after_drain;
integer space_lane;
always @* begin
  lanes_have_space=1'b1;
  lanes_empty_after_drain=1'b1;
  for (space_lane=0;space_lane<LANES;space_lane=space_lane+1) begin
    if (!transpose_mode) begin
      if (count_q[space_lane] == (PTR_BITS+1)'(DEPTH) && !dequeue[space_lane]) lanes_have_space=0;
    end else if (!trans_half_q) begin
      // The first half is reserved at tail, outside the visible FIFO count.
      if (count_q[space_lane] == (PTR_BITS+1)'(DEPTH)) lanes_have_space=0;
    end else if (count_q[space_lane] + 2 > DEPTH + dequeue[space_lane]) lanes_have_space=0;
    if (count_q[space_lane] != (PTR_BITS+1)'(dequeue[space_lane])) lanes_empty_after_drain=0;
  end
end
assign load_ready_o=busy_q && !load_complete_q && lanes_have_space;

always @(posedge clk or negedge rst_b) begin
  if (!rst_b) begin
    busy_q<=0; done_q<=0; load_complete_q<=0; trans_half_q<=0;
    stalled_q<=0;
    mode_q<=0; load_count_q<=0; trans_group_q<=0;
    for (lane_i=0;lane_i<LANES;lane_i=lane_i+1) begin
      head_q[lane_i]<=0; tail_q[lane_i]<=0; count_q[lane_i]<=0;
    end
  end else begin
    done_q<=0;
    stalled_q<=select_comb & ~drain_ready_i;
    if (start_i && start_ready_o) begin
      busy_q<=1; load_complete_q<=0; trans_half_q<=0;
      mode_q<=mode_i; load_count_q<=0; trans_group_q<=0;
      for (lane_i=0;lane_i<LANES;lane_i=lane_i+1) begin
        head_q[lane_i]<=0; tail_q[lane_i]<=0; count_q[lane_i]<=0;
      end
    end else if (busy_q) begin
      for (lane_i=0;lane_i<LANES;lane_i=lane_i+1) begin
        if (dequeue[lane_i]) head_q[lane_i]<=head_q[lane_i]+2'd1;
        case ({load_accept && enqueue_count!=0,dequeue[lane_i]})
          2'b10: count_q[lane_i]<=count_q[lane_i]+enqueue_count;
          2'b01: count_q[lane_i]<=count_q[lane_i]-3'd1;
          2'b11: count_q[lane_i]<=count_q[lane_i]+enqueue_count-3'd1;
          default: begin end
        endcase
      end

      if (load_accept) begin
        load_count_q<=load_count_q+3'd1;
        if (load_count_q+1 >= beat_limit) load_complete_q<=1'b1;
        if (!transpose_mode) begin
          for (lane_i=0;lane_i<LANES;lane_i=lane_i+1) begin
            data_mem[lane_i][tail_q[lane_i]]<=load_data_i[lane_i*32 +: 32];
            // A native beat contains 1/2/4 rows; each 32-bit chunk
            // contains 2/4/8 elements. Routing depends only on width.
            dot_mem[lane_i][tail_q[lane_i]]<=
                DOT_BITS'((int'(load_count_q) << mode_q[2:1]) + (lane_i >> (SLOT_BITS-int'(mode_q[2:1]))));
            slot_mem[lane_i][tail_q[lane_i]]<=
                SLOT_BITS'(lane_i & ((LANES >> mode_q[2:1])-1));
            tail_q[lane_i]<=PTR_BITS'(tail_q[lane_i]+1);
          end
        end else if (!trans_half_q) begin
          for (lane_i=0;lane_i<LANES;lane_i=lane_i+1)
            data_mem[lane_i][tail_q[lane_i]]<=load_data_i[lane_i*32 +: 32];
          trans_half_q<=1'b1;
        end else begin
          for (lane_i=0;lane_i<LANES;lane_i=lane_i+1) begin
            data_mem[lane_i][tail_q[lane_i]]<=
                transpose_chunk(mode_q,DOT_BITS'(lane_i*2),trans_beat0,load_data_i);
            dot_mem[lane_i][tail_q[lane_i]]<=DOT_BITS'(lane_i*2);
            slot_mem[lane_i][tail_q[lane_i]]<=trans_group_q[SLOT_BITS-1:0];
            data_mem[lane_i][PTR_BITS'(tail_q[lane_i]+1)]<=
                transpose_chunk(mode_q,DOT_BITS'(lane_i*2+1),trans_beat0,load_data_i);
            dot_mem[lane_i][PTR_BITS'(tail_q[lane_i]+1)]<=DOT_BITS'(lane_i*2+1);
            slot_mem[lane_i][PTR_BITS'(tail_q[lane_i]+1)]<=trans_group_q[SLOT_BITS-1:0];
            tail_q[lane_i]<=tail_q[lane_i]+2'd2;
          end
          trans_group_q<=trans_group_q+3'd1;
          trans_half_q<=1'b0;
        end
      end

      if (load_complete_q && !trans_half_q && lanes_empty_after_drain) begin
        busy_q<=0; done_q<=1;
      end
    end
  end
end
`ifndef SYNTHESIS
initial begin
  if (DOTS != 8 && DOTS != 16) $fatal(1,"WLD DOTS must be 8 or 16");
end
always @(posedge clk) begin
  if (rst_b && start_i && start_ready_o && mode_i > MODE_T4)
    $fatal(1,"WLD invalid element width");
end
`endif
endmodule
