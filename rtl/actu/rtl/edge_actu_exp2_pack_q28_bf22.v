`timescale 1ns/1ps

// Input is normalized: 2^28 <= mant_product_q28 < 2^29.
// One round-to-nearest-even at the BF22 destination.
module edge_actu_exp2_pack_q28_bf22 (
  input wire signed [9:0] exp2_k,
  input wire [28:0] mant_product_q28,
  output wire [21:0] value_bf22
);
wire [13:0] main = mant_product_q28[28:15];
wire [14:0] residue = mant_product_q28[14:0];
wire increment = residue[14] && (|residue[13:0] || main[0]);
wire [14:0] rounded = {1'b0,main} + {14'b0,increment};
wire signed [10:0] packed_exp = {exp2_k[9],exp2_k} + 11'sd127 +
                                {10'b0,rounded[14]};
wire [12:0] fraction = rounded[14] ? 13'b0 : rounded[12:0];
// EXP flushes range underflow and saturates overflow to positive infinity.
assign value_bf22 = (exp2_k < -10'sd126) ? 22'b0 :
                    ((exp2_k > 10'sd127 || packed_exp >= 11'sd255) ?
                     22'h1fe000 : {1'b0,packed_exp[7:0],fraction});
endmodule
