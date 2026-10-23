// Fixed packed pages: mode-specific static scatter, sequential pair drain.
// Full transaction storage; no per-slot variable input selection or relocation.
module edge_wld_fixed_group_buffer #(
 parameter WTYPE_BITS=2, parameter DOTS=8, parameter LANES=2, parameter DEPTH=LANES*DOTS/2,
 parameter GROUPS=DOTS/LANES, parameter PB=$clog2(DEPTH), parameter IB=$clog2(DOTS), parameter LB=$clog2(LANES)
)(
 input wire clk,rst_b,start_i, output wire start_ready_o,
 input wire [WTYPE_BITS-1:0] wtype_i, input wire transpose_i,
 input wire load_valid_i, output wire load_ready_o,
 input wire [DOTS*16-1:0] load_data_i,
 output wire [GROUPS-1:0] drain_valid_o, input wire drain_ready_i,
 output wire [GROUPS*32-1:0] drain_data_o,
 output wire [GROUPS*2-1:0] drain_lane_o,
 output wire [WTYPE_BITS-1:0] wtype_o, output wire busy_o, output reg done_o
);
 reg active_q,trans_q; reg [WTYPE_BITS-1:0] type_q;
 reg [IB:0] beat_q;
 wire [1:0] wc=type_q==0?0:type_q==3?2:1;
 wire [IB:0] limit=(IB+1)'(DOTS)>>wc;
 wire push=load_valid_i&&load_ready_o;
 wire [GROUPS-1:0] space,finished;
 assign load_ready_o=active_q&&beat_q<limit&&(&space);
 assign start_ready_o=!active_q;
 assign wtype_o=type_q;
 assign busy_o=active_q;
 always @(posedge clk or negedge rst_b) begin
  if(!rst_b)begin active_q<=0; trans_q<=0; type_q<=0; beat_q<=0; done_o<=0; end
  else begin
   done_o<=0;
   if(start_i&&start_ready_o)begin active_q<=1; trans_q<=transpose_i; type_q<=wtype_i; beat_q<=0; end
   else if(active_q)begin
    if(push)beat_q<=beat_q+1'b1;
    if(&finished)begin active_q<=0;done_o<=1;end
   end
  end
 end
 genvar g,s,k;
 generate for(g=0;g<GROUPS;g=g+1)begin: GROUP
  reg [31:0] mem[0:DEPTH-1];
  reg [PB-1:0] head_q;
  reg [PB:0] count_q;
  reg [1:0] sub_q;
  reg [IB+1:0] consumed_q;
  wire [IB+2:0] first_row={2'b0,beat_q} << wc;
  wire normal_hit=first_row<=g*LANES+LANES-1 && first_row+(1<<wc)>g*LANES;
  wire [IB:0] normal_amount=wc>LB ? (DOTS*LANES/2)>>wc : DOTS/2;
  wire [IB:0] amount=trans_q ? (beat_q[0]?LANES:0) : (normal_hit?normal_amount:0);
  wire pop=drain_valid_o[g]&&drain_ready_i;
  wire last_sub=sub_q==((3'd1<<wc)-1);
  wire release_word=pop&&last_sub;
  assign space[g]=1'b1; // Full packed BF16 transaction is reserved at start.
  assign finished[g]=consumed_q==LANES*DOTS/2;
  assign drain_valid_o[g]=active_q&&count_q!=0;
  assign drain_lane_o[g*2+:2]=trans_q?2'((consumed_q>>wc)%LANES):2'(consumed_q>>(IB-1));
  wire [31:0] word_data=mem[head_q];
  wire [31:0] shifted=wc==0?word_data:wc==1?(sub_q[0]?{16'b0,word_data[31:16]}:word_data):(word_data >> {sub_q,3'b0});
  assign drain_data_o[g*32+:32]=wc==0?shifted:wc==1?
    {8'b0,shifted[15:8],8'b0,shifted[7:0]}:
    {12'b0,shifted[7:4],12'b0,shifted[3:0]};
  // Front-end permutation and write schedule are co-designed. Each slot
  // has six compile-time source choices, never a tail-dependent barrel mux.
  for(s=0;s<DEPTH;s=s+1)begin: SLOT
   localparam D=g*LANES+s%LANES;
   localparam B0=(g*DEPTH+s)/(DOTS/2);
   localparam B1=(g*DEPTH/2+s)/(DOTS/2);
   localparam B2=(g*DEPTH/4+s)/(DOTS/2);
   localparam S0=(g*DEPTH+s)%(DOTS/2);
   localparam S1=(g*DEPTH/2+s)%(DOTS/2);
   localparam S2=(g*DEPTH/4+s)%(DOTS/2);
   wire [15:0] trans_half=wc==0?load_data_i[D*16+:16]:wc==1?
    {load_data_i[(DOTS+D)*8+:8],load_data_i[D*8+:8]}:
    {load_data_i[(3*DOTS+D)*4+:4],load_data_i[(2*DOTS+D)*4+:4],
     load_data_i[(DOTS+D)*4+:4],load_data_i[D*4+:4]};
   wire normal_write=wc==0?beat_q==B0:
     wc==1?(s<DEPTH/2 && beat_q==B1):(s<DEPTH/4 && beat_q==B2);
   wire [31:0] normal_word=wc==0?load_data_i[S0*32+:32]:
     wc==1?load_data_i[S1*32+:32]:load_data_i[S2*32+:32];
   always @(posedge clk)if(push)begin
    if(trans_q && (beat_q>>1)==s/LANES)begin
     if(beat_q[0])mem[s][31:16]<=trans_half;
     else mem[s][15:0]<=trans_half;
    end else if(!trans_q && normal_write)mem[s]<=normal_word;
   end
  end
  always @(posedge clk or negedge rst_b)begin
   if(!rst_b)begin head_q<=0;count_q<=0;sub_q<=0;consumed_q<=0;end
   else if(start_i&&start_ready_o)begin head_q<=0;count_q<=0;sub_q<=0;consumed_q<=0;end
   else begin
    count_q<=count_q+(push?amount:0)-release_word;
    if(pop)begin
     consumed_q<=consumed_q+1'b1;
     sub_q<=last_sub?0:sub_q+1'b1;
     if(last_sub)head_q<=head_q==DEPTH-1?0:head_q+1'b1;
    end
   end
  end
 end endgenerate
`ifndef SYNTHESIS
 initial begin
  if((DOTS!=8&&DOTS!=16&&DOTS!=32)||(LANES!=2&&LANES!=4)||DEPTH!=LANES*DOTS/2)
   $fatal(1,"unsupported fixed group geometry");
 end
`endif
endmodule
