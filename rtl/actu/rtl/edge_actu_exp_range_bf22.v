`timescale 1ns/1ps
// Q12 magnitude, Q14 coefficient, Q12 LUT code. Sign stays separate.
module edge_actu_exp_range_bf22(input [21:0] value_bf22,output underflow,output signed [9:0] exp2_k,output [11:0] frac_code);
wire sign_z;wire [18:0] magnitude_q12;
edge_actu_exp_range_bf22_prepare p(value_bf22,underflow,sign_z,magnitude_q12);
edge_actu_exp_range_bf22_scale s(sign_z,magnitude_q12,exp2_k,frac_code);
endmodule
module edge_actu_exp_range_bf22_prepare(input [21:0] value_bf22,output underflow,sign_z,output [18:0] magnitude_q12);
wire [7:0] exponent=value_bf22[20:13];
wire [28:0] shifted={15'b0,1'b1,value_bf22[12:0]} << exponent[3:0];
wire [18:0] finite_magnitude=exponent[7] ? shifted[18:0] : {6'b0,shifted[28:16]};
assign sign_z=value_bf22[21];
assign underflow=sign_z && value_bf22>=22'h30ab80;
wire clamp_high=!sign_z && value_bf22[20:0]>=21'h10ac00;
assign magnitude_q12=(underflow || exponent==255 || exponent<115) ? 19'b0 : clamp_high ? 19'd360448 : finite_magnitude;
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
