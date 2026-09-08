`timescale 1ns/1ps
// Q12 magnitude, Q14 coefficient, Q12 LUT code. Sign stays separate.
module edge_actu_exp_range_bf22(input [21:0] value_bf22,output underflow,output signed [9:0] exp2_k,output [11:0] frac_code);
wire sign_z;wire [18:0] magnitude_q12;
wire signed [9:0] numeric_k;wire [11:0] numeric_frac;
edge_actu_exp_range_bf22_prepare p(value_bf22,underflow,sign_z,magnitude_q12);
edge_actu_exp_range_bf22_scale s(sign_z,magnitude_q12,numeric_k,numeric_frac);
assign exp2_k=value_bf22==22'h1fe000 ? 10'sd128 : numeric_k;
assign frac_code=value_bf22==22'h1fe000 ? 12'b0 : numeric_frac;
endmodule
module edge_actu_exp_range_bf22_prepare(input [21:0] value_bf22,output underflow,sign_z,output [18:0] magnitude_q12);
// Standalone raw-bit compatibility boundary; integrated ingress uses numeric
// preparation directly and transports generated overflow separately.
wire [18:0] numeric_magnitude;
edge_actu_exp_range_bf22_prepare_numeric n(value_bf22,underflow,sign_z,numeric_magnitude);
assign magnitude_q12=(&value_bf22[20:13]) ? 19'b0 : numeric_magnitude;
endmodule
module edge_actu_exp_range_bf22_prepare_numeric #(parameter FREE_RUN=0)(input [21:0] value_bf22,output underflow,sign_z,output [18:0] magnitude_q12,output clamp_high);
wire [7:0] exponent=value_bf22[20:13];
wire [28:0] shifted={15'b0,1'b1,value_bf22[12:0]} << exponent[3:0];
wire [18:0] finite_magnitude=exponent[7] ? shifted[18:0] : {6'b0,shifted[28:16]};
assign sign_z=value_bf22[21];
assign underflow=sign_z && value_bf22>=22'h30ab80;
assign clamp_high=!sign_z && value_bf22[20:0]>=21'h10ac00;
// Tiny-to-Q12 truncation is numeric conversion; status never gates FREE_RUN.
assign magnitude_q12=FREE_RUN ? (exponent<115 ? 19'b0 : finite_magnitude) :
 (underflow || exponent<115) ? 19'b0 : clamp_high ? 19'd360448 : finite_magnitude;
endmodule
module edge_actu_exp_range_bf22_scale(input sign_z,input [18:0] magnitude_q12,output signed [9:0] exp2_k,output [11:0] frac_code);
wire [33:0] product=magnitude_q12*15'd23637;
wire negative_nonzero=sign_z && (|magnitude_q12);
// Deliberate complement policy includes a one-code bias on exact Q12-grid products.
assign exp2_k={2'b0,product[33:26]}^{10{negative_nonzero}};
assign frac_code=product[25:14]^{12{negative_nonzero}};
endmodule

module edge_actu_exp_range_bf22_scale_parts(input negative_nonzero,input [15:0] low_q,input [23:0] high_q,output signed [9:0] exp2_k,output [11:0] frac_code);
wire [24:0] combined={1'b0,high_q}+low_q;
wire [19:0] code=combined[23:4];
assign exp2_k={2'b0,code[19:12]}^{10{negative_nonzero}};
assign frac_code=code[11:0]^{12{negative_nonzero}};
endmodule
