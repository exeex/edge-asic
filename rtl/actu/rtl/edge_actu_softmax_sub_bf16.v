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

// Four captures: decode, alignment, addition, normalization/RNE.
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
reg [56:0] decoded_q;
reg [48:0] aligned_q;
reg [37:0] sum_q;
reg [3:0] valid_q;
edge_actu_softmax_sub_decode x_decode(value_bf16,max_bf16,decoded);
edge_actu_softmax_sub_align x_align(decoded_q,aligned);
edge_actu_softmax_sub_add x_add(aligned_q,sum_packet);
edge_actu_softmax_sub_pack x_pack(sum_q,packed_value);
always @(posedge clk) begin
  decoded_q<=decoded; aligned_q<=aligned; sum_q<=sum_packet;
  delta_bf16<=packed_value;
end
always @(posedge clk or negedge cpurst_b)
  if (!cpurst_b) valid_q<=0;
  else valid_q<={valid_q[2:0],in_valid};
assign out_valid=valid_q[3];
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
wire [15:0] large_operand=b_larger?b:a;
wire [15:0] small_operand=b_larger?a:b;
wire [7:0] large_exp=large_operand[14:7]==0?8'd1:large_operand[14:7];
wire [7:0] small_exp=small_operand[14:7]==0?8'd1:small_operand[14:7];
wire [7:0] shift=large_exp-small_exp;
wire [10:0] large_sig={(|large_operand[14:7]),large_operand[6:0],3'b0};
wire [10:0] small_sig={(|small_operand[14:7]),small_operand[6:0],3'b0};
wire same_sign=large_operand[15]==small_operand[15];
wire bypass=(a[14:0]==0)||(b[14:0]==0)||
            (a[14:7]==8'hff)||(b[14:7]==8'hff);
wire [15:0] bypass_value=a[14:0]==0?b:b[14:0]==0?a:16'h7fc0;
assign packet={bypass,bypass_value,large_operand[15],large_exp,same_sign,large_sig,small_sig,shift};
endmodule

module edge_actu_softmax_sub_align (
  input wire [56:0] packet,
  output wire [48:0] aligned_packet
);
wire bypass,sign_z,same_sign;
wire [15:0] bypass_value;
wire [7:0] exponent,shift;
wire [10:0] large_sig,small_sig;
assign {bypass,bypass_value,sign_z,exponent,same_sign,large_sig,small_sig,shift}=packet;
wire [10:0] shifted=small_sig>>shift;
wire sticky=shift>=11 ? |small_sig : |(small_sig & ((11'b1<<shift)-11'b1));
wire [10:0] aligned_small=shifted|{10'b0,sticky};
assign aligned_packet={bypass,bypass_value,sign_z,exponent,same_sign,large_sig,aligned_small};
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
