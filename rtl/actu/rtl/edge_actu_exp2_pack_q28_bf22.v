`timescale 1ns/1ps

// Input is normalized: 2^28 <= mant_product_q28 < 2^29.
// One round-to-nearest-even at the BF22 destination.
module edge_actu_exp2_pack_q28_bf22 (
  input wire signed [9:0] exp2_k,
  input wire [28:0] mant_product_q28,
  output wire [21:0] value_bf22
);
wire [21:0] candidate;
wire [2:0] value_class;
edge_actu_exp2_pack_q28_bf22_classified n(exp2_k,mant_product_q28,candidate,value_class);
// Raw-bit compatibility wrapper. Integrated frontend consumes candidate/status.
assign value_bf22=value_class==3'd1 ? 22'b0 :
                  value_class==3'd4 ? 22'h1fe000 : candidate;
endmodule

module edge_actu_exp2_pack_q28_bf22_classified (
  input wire signed [9:0] exp2_k,
  input wire [28:0] mant_product_q28,
  output wire [21:0] candidate_bf22,
  output wire [2:0] value_class
);
wire [13:0] main = mant_product_q28[28:15];
wire [14:0] residue = mant_product_q28[14:0];
wire increment = residue[14] && (|residue[13:0] || main[0]);
wire [14:0] rounded = {1'b0,main} + {14'b0,increment};
wire signed [10:0] packed_exp = {exp2_k[9],exp2_k} + 11'sd127 +
                                {10'b0,rounded[14]};
wire [12:0] fraction = rounded[14] ? 13'b0 : rounded[12:0];
// RNE/exponent carry belongs to arithmetic; no zero/Inf materialization here.
assign candidate_bf22={1'b0,packed_exp[7:0],fraction};
assign value_class=(exp2_k < -10'sd126) ? 3'd1 :
                   (exp2_k > 10'sd127 || packed_exp >= 11'sd255) ? 3'd4 : 3'd0;
endmodule
