// One dot's normalized raw-element buffer. Width affects only unpack/write;
// every read pops one 16-bit transport slot in the same increasing order.
module edge_wld_dot_ingress #(
  parameter DOT_SIZE=8, parameter INDEX_BITS=$clog2(DOT_SIZE), parameter WTYPE_BITS=2
)(
  input wire clk,input wire rst_b,input wire start_i,input wire [1:0] width_code_i,
  input wire [WTYPE_BITS-1:0] wtype_i,
  input wire advance_i,input wire valid_i,output wire ready_o,input wire [31:0] data_i,
  output wire element_valid_o,output wire [15:0] element_o,output reg done_o,
  output wire busy_o,output wire [WTYPE_BITS-1:0] wtype_o
);
reg [15:0] queue_q[0:DOT_SIZE-1];
reg [INDEX_BITS-1:0] head_q,tail_q;
reg [INDEX_BITS:0] count_q;
reg [1:0] width_q;
reg [WTYPE_BITS-1:0] wtype_q;
reg [INDEX_BITS-1:0] element_count_q;
reg active_q;
wire [INDEX_BITS:0] push_count=(INDEX_BITS+1)'(2)<<width_q;
wire pop=element_valid_o;
wire push=valid_i&&ready_o;
assign ready_o=active_q && advance_i
               && ({1'b0,count_q}+{1'b0,push_count}
                   <= (INDEX_BITS+2)'(DOT_SIZE)+(INDEX_BITS+2)'(pop));
assign element_valid_o=active_q && advance_i && count_q!=0;
assign element_o=queue_q[head_q];
assign busy_o=active_q;
// Wtype remains load-latched sideband for the downstream dot ingress. It does
// not select a read mux, change the read stride, or choose a relay direction.
assign wtype_o=wtype_q;

// Each storage cell has one write enable/data source. Normalize packed 16/8/4
// bit words here; narrow values retain raw bits and are only zero-extended.
// Tail advances by the same aligned group size, so each slot's subword
// source is constant wiring rather than a variable write-data crossbar.
// Signed/floating numerical decoding remains at the dot's weight ingress.
genvar slot_g;
generate for(slot_g=0;slot_g<DOT_SIZE;slot_g=slot_g+1)begin : GEN_SLOT
  wire [INDEX_BITS-1:0] offset=INDEX_BITS'(slot_g)-tail_q;
  reg [15:0] write_data;
  always @*begin
    case(width_q)
      0:write_data=data_i[(slot_g%2)*16+:16];
      1:write_data={8'b0,data_i[(slot_g%4)*8+:8]};
      default:write_data={12'b0,data_i[(slot_g%8)*4+:4]};
    endcase
  end
  always @(posedge clk)
    if(push && {1'b0,offset}<push_count)queue_q[slot_g]<=write_data;
end endgenerate

always @(posedge clk or negedge rst_b)begin
 if(!rst_b)begin
  head_q<=0;tail_q<=0;count_q<=0;width_q<=0;wtype_q<=0;element_count_q<=0;active_q<=0;done_o<=0;
 end else begin
  done_o<=0;
  if(start_i)begin
   head_q<=0;tail_q<=0;count_q<=0;width_q<=width_code_i;wtype_q<=wtype_i;
   element_count_q<=0;active_q<=1;
  end else begin
   if(push)tail_q<=tail_q+INDEX_BITS'(push_count);
   // The sole consumer path: one slot, one address increment, for every mode.
   if(pop)head_q<=head_q+1'b1;
   case({push,pop})
    2'b10:count_q<=count_q+push_count;
    2'b01:count_q<=count_q-1'b1;
    2'b11:count_q<=count_q+push_count-1'b1;
    default:begin end
   endcase
   if(pop)begin
    element_count_q<=element_count_q+1'b1;
    if(element_count_q==INDEX_BITS'(DOT_SIZE-1))begin active_q<=0;done_o<=1;end
   end
  end
 end
end
`ifndef SYNTHESIS
initial if(DOT_SIZE!=8&&DOT_SIZE!=16)$fatal(1,"invalid dot ingress shape");
always @(posedge clk)begin
 if(rst_b&&start_i&&width_code_i>2)$fatal(1,"invalid dot ingress wtype");
 if(rst_b&&push&&({1'b0,tail_q}&(push_count-1'b1))!=0)$fatal(1,"unaligned normalized buffer write");
 if(rst_b&&done_o&&count_q!=0)$fatal(1,"dot ingress completed with queued elements");
end
`endif
endmodule
