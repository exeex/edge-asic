`timescale 1ns/1ps

// Native BF16 operands and destination, with a single RNE.
module edge_actu_softmax_sub_bf16 (
  input wire [15:0] value_bf16, max_bf16,
  output wire [15:0] delta_bf16
);
wire [56:0] decoded;
wire [48:0] aligned;
wire [37:0] sum_packet;
edge_actu_softmax_sub_decode x_decode(value_bf16,max_bf16,decoded);
edge_actu_softmax_sub_align x_align(decoded,aligned);
edge_actu_softmax_sub_add x_add(aligned,sum_packet);
edge_actu_softmax_sub_pack x_pack(sum_packet,delta_bf16);
endmodule

// Five captures: parallel decode, coarse/fine alignment, addition, normalization/RNE.
module edge_actu_softmax_sub_bf16_pipe (
  input wire clk, cpurst_b, in_valid,
  input wire [15:0] value_bf16, max_bf16,
  output wire out_valid,
  output reg [15:0] delta_bf16
);
wire [56:0] decoded;
wire [48:0] aligned;
wire [37:0] sum_packet;
wire [15:0] packed_value;
wire [50:0] coarse;
reg [50:0] coarse_q;
reg [56:0] decoded_q;
reg [48:0] aligned_q;
reg [37:0] sum_q;
reg [4:0] valid_q;
edge_actu_softmax_sub_decode x_decode(value_bf16,max_bf16,decoded);
edge_actu_softmax_sub_align_coarse x_coarse(decoded_q,coarse);
edge_actu_softmax_sub_align_fine x_fine(coarse_q,aligned);
edge_actu_softmax_sub_add x_add(aligned_q,sum_packet);
edge_actu_softmax_sub_pack x_pack(sum_q,packed_value);
always @(posedge clk) begin
  decoded_q<=decoded; coarse_q<=coarse; aligned_q<=aligned; sum_q<=sum_packet;
  delta_bf16<=packed_value;
end
always @(posedge clk or negedge cpurst_b)
  if (!cpurst_b) valid_q<=0;
  else valid_q<={valid_q[3:0],in_valid};
assign out_valid=valid_q[4];
endmodule

// Packet: bypass, BF16 bypass value, sign, exponent, same sign, two
// 11-bit significands (8 main + GRS), alignment distance.
module edge_actu_softmax_sub_decode (
  input wire [15:0] value_bf16, max_bf16,
  output wire [56:0] packet
);
wire [15:0] a=value_bf16;
wire [15:0] b={~max_bf16[15],max_bf16[14:0]};
wire b_larger=b[14:0]>a[14:0];
// Exponent decode and both distances run independently of magnitude ordering.
wire [7:0] a_exp=(a[14:7]==0)?8'd1:a[14:7];
wire [7:0] b_exp=(b[14:7]==0)?8'd1:b[14:7];
wire [7:0] a_minus_b=a_exp-b_exp;
wire [7:0] b_minus_a=b_exp-a_exp;
wire [7:0] large_exp=b_larger?b_exp:a_exp;
wire [7:0] shift=b_larger?b_minus_a:a_minus_b;
wire [10:0] a_sig={(|a[14:7]),a[6:0],3'b0};
wire [10:0] b_sig={(|b[14:7]),b[6:0],3'b0};
wire [10:0] large_sig=b_larger?b_sig:a_sig;
wire [10:0] small_sig=b_larger?a_sig:b_sig;
wire sign_z=b_larger?b[15]:a[15];
wire same_sign=a[15]==b[15];
wire bypass=(a[14:0]==0)||(b[14:0]==0)||
            (a[14:7]==8'hff)||(b[14:7]==8'hff);
wire [15:0] bypass_value=a[14:0]==0?b:b[14:0]==0?a:16'h7fc0;
assign packet={bypass,bypass_value,sign_z,large_exp,same_sign,large_sig,small_sig,shift};
endmodule

// Combinational wrapper retained for the arithmetic oracle boundary.
module edge_actu_softmax_sub_align (
  input wire [56:0] packet,
  output wire [48:0] aligned_packet
);
wire [50:0] coarse;
edge_actu_softmax_sub_align_coarse x_coarse(packet,coarse);
edge_actu_softmax_sub_align_fine x_fine(coarse,aligned_packet);
endmodule

// Jam discarded bits into bit zero at each step. Jammed right shifts compose.
module edge_actu_softmax_sub_align_coarse (
  input wire [56:0] packet,
  output wire [50:0] coarse_packet
);
wire [7:0] shift=packet[7:0];
wire [10:0] small_sig=packet[18:8];
reg [10:0] shifted;
always @* begin
  if ((|shift[7:4]) || (&shift[3:2])) shifted={10'b0,|small_sig};
  else case(shift[3:2])
    2'd1: shifted={4'b0,small_sig[10:5],|small_sig[4:0]};
    2'd2: shifted={8'b0,small_sig[10:9],|small_sig[8:0]};
    default: shifted=small_sig;
  endcase
end
assign coarse_packet={packet[56:19],shifted,shift[1:0]};
endmodule

module edge_actu_softmax_sub_align_fine (
  input wire [50:0] packet,
  output wire [48:0] aligned_packet
);
wire [10:0] small_sig=packet[12:2];
reg [10:0] shifted;
always @* begin
  case(packet[1:0])
    2'd1: shifted={1'b0,small_sig[10:2],|small_sig[1:0]};
    2'd2: shifted={2'b0,small_sig[10:3],|small_sig[2:0]};
    2'd3: shifted={3'b0,small_sig[10:4],|small_sig[3:0]};
    default: shifted=small_sig;
  endcase
end
assign aligned_packet={packet[50:13],shifted};
endmodule

module edge_actu_softmax_sub_add (
  input wire [48:0] packet,
  output wire [37:0] sum_packet
);
wire bypass,sign_z,same_sign;
wire [15:0] bypass_value;
wire [7:0] exponent;
wire [10:0] large_sig,aligned_small;
assign {bypass,bypass_value,sign_z,exponent,same_sign,large_sig,aligned_small}=packet;
wire [10:0] addend=aligned_small^{11{!same_sign}};
wire [11:0] raw_sum={1'b0,large_sig}+{1'b0,addend}+{11'b0,!same_sign};
wire [11:0] sum={raw_sum[11]&&same_sign,raw_sum[10:0]};
assign sum_packet={bypass,bypass_value,sign_z,exponent,sum};
endmodule

module edge_actu_softmax_sub_pack (
  input wire [37:0] packet,
  output reg [15:0] delta_bf16
);
wire bypass,sign_z;
wire [15:0] bypass_value;
wire [7:0] large_exp;
wire [11:0] sum;
assign {bypass,bypass_value,sign_z,large_exp,sum}=packet;
reg [10:0] normalized,probe;
reg [3:0] count;
reg [8:0] exponent,rounded;
reg increment;
always @* begin
  normalized=sum[11]?{sum[11:2],|sum[1:0]}:sum[10:0];
  exponent={1'b0,large_exp}+{8'b0,sum[11]};
  probe=normalized; count=0;
  if(probe[10:3]==0)begin probe=probe<<8;count=count+4'd8;end
  if(probe[10:7]==0)begin probe=probe<<4;count=count+4'd4;end
  if(probe[10:9]==0)begin probe=probe<<2;count=count+4'd2;end
  if(!probe[10])begin probe=probe<<1;count=count+4'd1;end
  if({5'b0,count}>=exponent)begin
    count=exponent[3:0]-4'd1;
    normalized=normalized<<count;
  end else normalized=probe;
  exponent=exponent-{5'b0,count};
  increment=normalized[2]&&(|normalized[1:0]||normalized[3]);
  rounded={1'b0,normalized[10:3]}+{8'b0,increment};
  if(rounded[8])begin rounded=rounded>>1;exponent=exponent+9'd1;end
  if(!rounded[7])exponent=0;
  if(bypass)delta_bf16=bypass_value;
  else if(sum==0)delta_bf16=0;
  else if(exponent>=255)delta_bf16={sign_z,8'hff,7'b0};
  else delta_bf16={sign_z,exponent[7:0],rounded[6:0]};
end
endmodule
