`timescale 1ns/1ps

// Native BF16 operands, single BF22 RNE. The combinational and two-stage
// candidates share arithmetic; only the packet register boundary differs.
module edge_actu_softmax_sub_bf16 (
  input wire [15:0] value_bf16, max_bf16,
  output wire [21:0] delta_bf22
);
wire [49:0] packet;
edge_actu_softmax_sub_prepare x_prepare(value_bf16,max_bf16,packet);
edge_actu_softmax_sub_pack x_pack(packet,delta_bf22);
endmodule

module edge_actu_softmax_sub_bf16_pipe (
  input wire clk, cpurst_b, in_valid,
  input wire [15:0] value_bf16, max_bf16,
  output reg out_valid,
  output reg [21:0] delta_bf22
);
wire [49:0] packet;
wire [21:0] packed_value;
reg [49:0] packet_q;
reg valid_q;
edge_actu_softmax_sub_prepare x_prepare(value_bf16,max_bf16,packet);
edge_actu_softmax_sub_pack x_pack(packet_q,packed_value);
always @(posedge clk) begin
  packet_q <= packet;
  delta_bf22 <= packed_value;
end
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin valid_q <= 0; out_valid <= 0; end
  else begin valid_q <= in_valid; out_valid <= valid_q; end
end
endmodule

// Packet: special bypass, bypass BF22, sign, exponent and 18-bit raw sum.
module edge_actu_softmax_sub_prepare (
  input wire [15:0] value_bf16, max_bf16,
  output wire [49:0] packet
);
wire [15:0] a = value_bf16;
wire [15:0] b = {~max_bf16[15],max_bf16[14:0]};
wire b_larger = b[14:0] > a[14:0];
wire [15:0] large_operand = b_larger ? b : a;
wire [15:0] small_operand = b_larger ? a : b;
wire [7:0] large_exp = large_operand[14:7] == 0 ? 8'd1 : large_operand[14:7];
wire [7:0] small_exp = small_operand[14:7] == 0 ? 8'd1 : small_operand[14:7];
wire [7:0] shift = large_exp - small_exp;
// 14 main bits (BF22) and guard/round/sticky; BF16 has only 8 sig bits.
wire [16:0] large_sig = {(|large_operand[14:7]),large_operand[6:0],9'b0};
wire [16:0] small_sig = {(|small_operand[14:7]),small_operand[6:0],9'b0};
wire [16:0] shifted = small_sig >> shift;
wire sticky = shift >= 17 ? |small_sig :
              |(small_sig & ((17'b1 << shift) - 17'b1));
wire [16:0] aligned_small = shifted | {16'b0,sticky};
wire same_sign = large_operand[15] == small_operand[15];
// One shared adder; discard subtraction's carry-out.
wire [16:0] addend = aligned_small ^ {17{!same_sign}};
wire [17:0] raw_sum = {1'b0,large_sig} + {1'b0,addend} + {17'b0,!same_sign};
wire [17:0] sum = {raw_sum[17] && same_sign,raw_sum[16:0]};
wire bypass = (a[14:0] == 0) || (b[14:0] == 0) ||
              (a[14:7] == 8'hff) || (b[14:7] == 8'hff);
wire [21:0] bypass_value = a[14:0] == 0 ? {b,6'b0} :
                           b[14:0] == 0 ? {a,6'b0} : 22'h1ff000;
assign packet = {bypass,bypass_value,large_operand[15],large_exp,sum};
endmodule

module edge_actu_softmax_sub_pack (
  input wire [49:0] packet,
  output reg [21:0] delta_bf22
);
wire bypass,sign_z;
wire [21:0] bypass_value;
wire [7:0] large_exp;
wire [17:0] sum;
assign {bypass,bypass_value,sign_z,large_exp,sum} = packet;
reg [16:0] normalized, probe;
reg [4:0] count;
reg [8:0] exponent;
reg [14:0] rounded;
reg increment;
always @* begin
  normalized = sum[17] ? {sum[17:2],|sum[1:0]} : sum[16:0];
  exponent = {1'b0,large_exp} + {8'b0,sum[17]};
  probe = normalized;
  count = 0;
  if (probe[16:1] == 0) begin probe = probe << 16; count = count + 5'd16; end
  if (probe[16:9] == 0) begin probe = probe << 8; count = count + 5'd8; end
  if (probe[16:13] == 0) begin probe = probe << 4; count = count + 5'd4; end
  if (probe[16:15] == 0) begin probe = probe << 2; count = count + 5'd2; end
  if (!probe[16]) count = count + 5'd1;
  // Keep exponent one for a subnormal; packing below restores exponent zero.
  if ({4'b0,count} >= exponent) count = exponent[4:0] - 5'd1;
  normalized = normalized << count;
  exponent = exponent - {4'b0,count};
  increment = normalized[2] && (|normalized[1:0] || normalized[3]);
  rounded = {1'b0,normalized[16:3]} + {14'b0,increment};
  if (rounded[14]) begin
    rounded = rounded >> 1;
    exponent = exponent + 9'd1;
  end
  if (!rounded[13]) exponent = 0;
  if (bypass) delta_bf22 = bypass_value;
  else if (sum == 0) delta_bf22 = 0;
  else if (exponent >= 255) delta_bf22 = {sign_z,8'hff,13'b0};
  else delta_bf22 = {sign_z,exponent[7:0],rounded[12:0]};
end
endmodule
