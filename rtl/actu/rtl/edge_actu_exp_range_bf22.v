`timescale 1ns/1ps

// Native BF22 range reduction. Q16 truncates magnitude toward zero; the
// signed log2 code floors only after multiplication, matching the EXP table.
module edge_actu_exp_range_bf22 (
  input wire [21:0] value_bf22,
  output wire underflow,
  output wire signed [9:0] exp2_k,
  output wire [11:0] frac_code
);
wire sign_z;
wire [22:0] magnitude_q16;
edge_actu_exp_range_bf22_prepare x_prepare(value_bf22,underflow,sign_z,magnitude_q16);
edge_actu_exp_range_bf22_scale x_scale(sign_z,magnitude_q16,exp2_k,frac_code);
endmodule

module edge_actu_exp_range_bf22_prepare (
  input wire [21:0] value_bf22,
  output wire underflow,
  output wire sign_z,
  output wire [22:0] magnitude_q16
);
wire [7:0] exponent = value_bf22[20:13];
wire is_special = exponent == 8'hff;
wire clamp_high = !sign_z && (value_bf22[20:0] >= 21'h10ac00);
wire tiny = exponent < 8'd111; // abs(x) < 2^-16 cannot contribute to Q16.
// For active exponents 111..133, Q16 = significand * 2^(exponent-124).
// Shift only by the low four exponent bits; fixed slices supply the scale.
wire [28:0] shifted = {15'b0,1'b1,value_bf22[12:0]} << exponent[3:0];
wire [22:0] finite_magnitude = exponent[7] ? {shifted[18:0],4'b0} :
                               exponent[4] ? {6'b0,shifted[28:12]} : 23'd1;
assign sign_z = value_bf22[21];
assign underflow = sign_z && (value_bf22 >= 22'h30ab80);
assign magnitude_q16 = (underflow || is_special || tiny) ? 23'b0 :
                       clamp_high ? 23'd5767168 : finite_magnitude;
endmodule

module edge_actu_exp_range_bf22_scale (
  input wire sign_z,
  input wire [22:0] magnitude_q16,
  output wire signed [9:0] exp2_k,
  output wire [11:0] frac_code
);
// magnitude <= 88*65536. Product needs 52 bits; signed code needs 20.
wire [51:0] product = magnitude_q16 * 29'd387270501;
wire [19:0] positive_code = product[51:32];
wire [19:0] code = sign_z ? (~positive_code + {19'b0,!(|product[31:0])}) : positive_code;
assign exp2_k = {{2{code[19]}},code[19:12]};
assign frac_code = code[11:0];
endmodule
