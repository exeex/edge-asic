module edge_psum(
  a_raw,
  b_raw,
  y
);

input  [15:0] a_raw;
input  [15:0] b_raw;
output [15:0] y;

assign y[15:0] = bf16_add(a_raw[15:0], b_raw[15:0]);

function [15:0] sanitize_bf16;
  input [15:0] value;
  begin
    if ((value[14:7] == 8'hff) && (value[6:0] != 7'b0))
      sanitize_bf16 = 16'h0000;
    else if ((value[14:0] == 15'h7f80))
      sanitize_bf16 = value[15] ? 16'hff7f : 16'h7f7f;
    else
      sanitize_bf16 = value;
  end
endfunction

function [15:0] rshift_rne16;
  input [15:0] value;
  input [7:0]  amount;
  reg [15:0] quotient;
  reg [15:0] remainder;
  reg [15:0] half;
  reg [15:0] mask;
  begin
    if (amount == 8'b0) begin
      rshift_rne16 = value;
    end else if (amount >= 8'd15) begin
      rshift_rne16 = 16'b0;
    end else begin
      quotient = value >> amount;
      mask = (16'h1 << amount) - 16'h1;
      remainder = value & mask;
      half = 16'h1 << (amount - 1'b1);
      rshift_rne16 = quotient
                   + ((remainder > half)
                      || ((remainder == half) && quotient[0]));
    end
  end
endfunction

function [3:0] msb_index11;
  input [10:0] value;
  integer idx;
  begin
    msb_index11 = 4'b0;
    for (idx = 0; idx < 11; idx = idx + 1) begin
      if (value[idx])
        msb_index11 = idx[3:0];
    end
  end
endfunction

function [15:0] normalize_add_sum_to_bf16;
  input signed [10:0] sum;
  input [7:0] exp_base;
  reg sign;
  reg [10:0] mag;
  reg [3:0]  msb;
  reg [15:0] rounded;
  reg [8:0]  sig;
  reg [8:0]  sub_sig;
  integer exp_field;
  integer shift;
  begin
    if (sum == 11'sd0) begin
      normalize_add_sum_to_bf16 = 16'h0000;
    end else begin
      sign = sum[10];
      mag = sign ? -sum : sum;
      msb = msb_index11(mag);
      exp_field = {24'b0, exp_base} + msb - 7;

      if (exp_field >= 255) begin
        normalize_add_sum_to_bf16 = sign ? 16'hff7f : 16'h7f7f;
      end else if (exp_field <= 0) begin
        shift = {24'b0, exp_base} - 1;
        if (shift >= 0)
          rounded = {5'b0, mag} << shift;
        else
          rounded = rshift_rne16({5'b0, mag}, -shift);
        sub_sig = rounded[8:0];
        if (sub_sig >= 9'd128)
          normalize_add_sum_to_bf16 = {sign, 8'h01, 7'h00};
        else
          normalize_add_sum_to_bf16 = {sign, 8'h00, sub_sig[6:0]};
      end else begin
        shift = msb - 7;
        if (shift >= 0)
          rounded = rshift_rne16({5'b0, mag}, shift);
        else
          rounded = {5'b0, mag} << (-shift);

        sig = rounded[8:0];
        if (sig >= 9'd256) begin
          sig = {1'b0, sig[8:1]};
          exp_field = exp_field + 1;
        end

        if (exp_field >= 255)
          normalize_add_sum_to_bf16 = sign ? 16'hff7f : 16'h7f7f;
        else
          normalize_add_sum_to_bf16 = {sign, exp_field[7:0], sig[6:0]};
      end
    end
  end
endfunction

function [15:0] bf16_add;
  input [15:0] a_raw_in;
  input [15:0] b_raw_in;
  reg [15:0] a;
  reg [15:0] b;
  reg [7:0]  exp_a;
  reg [7:0]  exp_b;
  reg [7:0]  exp_o;
  reg [7:0]  sig_a;
  reg [7:0]  sig_b;
  reg [15:0] aligned_a;
  reg [15:0] aligned_b;
  reg signed [10:0] signed_a;
  reg signed [10:0] signed_b;
  reg signed [10:0] signed_sum;
  begin
    a = sanitize_bf16(a_raw_in);
    b = sanitize_bf16(b_raw_in);
    exp_a = a[14:7];
    exp_b = b[14:7];
    exp_o = (exp_a >= exp_b) ? exp_a : exp_b;
    sig_a = (exp_a == 8'b0) ? {1'b0, a[6:0]} : {1'b1, a[6:0]};
    sig_b = (exp_b == 8'b0) ? {1'b0, b[6:0]} : {1'b1, b[6:0]};
    aligned_a = rshift_rne16({8'b0, sig_a}, exp_o - exp_a);
    aligned_b = rshift_rne16({8'b0, sig_b}, exp_o - exp_b);
    signed_a = {3'b0, aligned_a[7:0]};
    signed_b = {3'b0, aligned_b[7:0]};
    if (a[15])
      signed_a = -signed_a;
    if (b[15])
      signed_b = -signed_b;
    signed_sum = signed_a + signed_b;
    bf16_add = normalize_add_sum_to_bf16(signed_sum, exp_o);
  end
endfunction

endmodule

// BF22 arithmetic in FP32 storage (1/8/13, low ten bits zero).
// Mirrors the dot/RSUM RNE format; normal arithmetic underflow flushes to zero.
// Wide exponent alignment retains the sticky bit at bit zero.
module edge_bf22_post_lane(
 input [31:0] dot_i, psum_i,
 input [15:0] scale_i,
 output [31:0] scaled_o, sum_o,
 output [15:0] sum_bf16_o
);
assign scaled_o = bf22_round_bits(multiply(dot_i, scale_i));
assign sum_o = bf22_round_bits(fp32_add_bits(dot_i, psum_i));
wire [31:0] rounded_bf16 = bf16_round_bits(sum_o);
assign sum_bf16_o = rounded_bf16[31:16];
function [31:0] bf16_round_bits;
  input [31:0] bits;
  reg [15:0] rounded;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      rounded = 16'h7fc0;
    end else begin
      rounded = bits[31:16]
              + {15'b0, (bits[15] && (|bits[14:0] || bits[16]))};
      if ((rounded == 16'h0000) && bits[31])
        rounded = 16'h8000;
    end
    bf16_round_bits = {rounded, 16'h0000};
  end
endfunction

function [31:0] bf22_round_bits;
  input [31:0] bits;
  reg [31:0] bias;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      bf22_round_bits = 32'h7fc0_0000;
    end else begin
      bias = 32'h0000_01ff + {31'b0, bits[10]};
      bf22_round_bits = (bits + bias) & 32'hffff_fc00;
    end
  end
endfunction

function [26:0] rshift_sticky27;
  input [26:0] value;
  input integer shift;
  reg sticky;
  begin
    if (shift <= 0) begin
      rshift_sticky27 = value;
    end else if (shift >= 27) begin
      rshift_sticky27 = {26'b0, |value};
    end else begin
      sticky = |(value & ((27'b1 << shift) - 27'b1));
      rshift_sticky27 = (value >> shift) | {26'b0, sticky};
    end
  end
endfunction

function [31:0] fp32_pack_from_grs;
  input        sign;
  input signed [11:0] exp_unbiased;
  input [26:0] sig_grs;
  reg [23:0] main;
  reg guard_bit;
  reg round_bit;
  reg sticky_bit;
  reg increment;
  reg [24:0] rounded;
  reg signed [11:0] packed_exp_unbiased;
  reg signed [12:0] biased_exp;
  begin
    if (sig_grs == 27'b0 || exp_unbiased < -12'sd126 || !sig_grs[26]) begin
      fp32_pack_from_grs = {sign, 31'b0};
    end else begin
      main = sig_grs[26:3];
      guard_bit = sig_grs[2];
      round_bit = sig_grs[1];
      sticky_bit = sig_grs[0];
      increment = guard_bit && (round_bit || sticky_bit || main[0]);
      rounded = {1'b0, main} + {24'b0, increment};
      packed_exp_unbiased = exp_unbiased + {11'b0, rounded[24]};
      biased_exp = packed_exp_unbiased + 13'sd127;
      if (biased_exp >= 13'sd255)
        fp32_pack_from_grs = {sign, 8'hfe, 23'h7fffff};
      else if (biased_exp <= 13'sd0)
        fp32_pack_from_grs = {sign, 31'b0};
      else
        fp32_pack_from_grs = {sign, biased_exp[7:0],
                              rounded[24] ? rounded[23:1]
                                          : rounded[22:0]};
    end
  end
endfunction

function [31:0] fp32_add_bits;
  input [31:0] a_bits;
  input [31:0] b_bits;
  reg        sign_a;
  reg        sign_b;
  reg [7:0]  exp_a_bits;
  reg [7:0]  exp_b_bits;
  reg [23:0] sig_a;
  reg [23:0] sig_b;
  reg signed [11:0] exp_a;
  reg signed [11:0] exp_b;
  reg        large_sign;
  reg        small_sign;
  reg signed [11:0] large_exp;
  reg [26:0] large_sig;
  reg [26:0] small_sig;
  reg [27:0] add_sig;
  reg [26:0] norm_sig;
  integer shift_amt;
  integer norm_count;
  begin
    sign_a = a_bits[31];
    sign_b = b_bits[31];
    exp_a_bits = a_bits[30:23];
    exp_b_bits = b_bits[30:23];
    sig_a = (exp_a_bits == 8'b0) ? {1'b0, a_bits[22:0]}
                                  : {1'b1, a_bits[22:0]};
    sig_b = (exp_b_bits == 8'b0) ? {1'b0, b_bits[22:0]}
                                  : {1'b1, b_bits[22:0]};
    exp_a = (exp_a_bits == 8'b0) ? -12'sd126
                                  : ({4'b0, exp_a_bits} - 12'sd127);
    exp_b = (exp_b_bits == 8'b0) ? -12'sd126
                                  : ({4'b0, exp_b_bits} - 12'sd127);

    if (a_bits[30:0] == 31'b0) begin
      fp32_add_bits = b_bits;
    end else if (b_bits[30:0] == 31'b0) begin
      fp32_add_bits = a_bits;
    end else if (exp_a_bits == 8'hff || exp_b_bits == 8'hff) begin
      fp32_add_bits = 32'h7fc0_0000;
    end else begin
      if ((exp_b > exp_a) || ((exp_b == exp_a) && (sig_b > sig_a))) begin
        large_sign = sign_b;
        small_sign = sign_a;
        large_exp = exp_b;
        large_sig = {sig_b, 3'b0};
        shift_amt = $signed({{20{exp_b[11]}}, exp_b})
                  - $signed({{20{exp_a[11]}}, exp_a});
        small_sig = rshift_sticky27({sig_a, 3'b0}, shift_amt);
      end else begin
        large_sign = sign_a;
        small_sign = sign_b;
        large_exp = exp_a;
        large_sig = {sig_a, 3'b0};
        shift_amt = $signed({{20{exp_a[11]}}, exp_a})
                  - $signed({{20{exp_b[11]}}, exp_b});
        small_sig = rshift_sticky27({sig_b, 3'b0}, shift_amt);
      end

      if (large_sign == small_sign) begin
        add_sig = {1'b0, large_sig} + {1'b0, small_sig};
        if (add_sig[27]) begin
          norm_sig = {add_sig[27:2], |add_sig[1:0]};
          large_exp = large_exp + 12'sd1;
        end else begin
          norm_sig = add_sig[26:0];
        end
        fp32_add_bits = fp32_pack_from_grs(large_sign, large_exp, norm_sig);
      end else if (large_sig == small_sig) begin
        fp32_add_bits = 32'b0;
      end else begin
        norm_sig = large_sig - small_sig;
        for (norm_count = 0; norm_count < 24;
             norm_count = norm_count + 1) begin
          if (!norm_sig[26] && (large_exp > -12'sd126)) begin
            norm_sig = norm_sig << 1;
            large_exp = large_exp - 12'sd1;
          end
        end
        fp32_add_bits = fp32_pack_from_grs(large_sign, large_exp, norm_sig);
      end
    end
  end
endfunction


function [31:0] multiply;
 input [31:0] a;
 input [15:0] b;
 reg [13:0] am;
 reg [7:0] bm;
 reg [21:0] product;
 reg [26:0] normalized;
 reg signed [11:0] exponent;
 integer msb, j;
 begin
  am = {a[30:23]!=0,a[22:10]};
  bm = {b[14:7]!=0,b[6:0]};
  product = am * bm;
  msb=0;
  for(j=0;j<22;j=j+1) if(product[j]) msb=j;
  normalized = {5'b0,product} << (26-msb);
  exponent = (a[30:23]==0 ? -12'sd126 : $signed({4'b0,a[30:23]})-12'sd127)
           + (b[14:7]==0 ? -12'sd126 : $signed({4'b0,b[14:7]})-12'sd127)
           + 12'(msb) - 12'sd20;
  if(a[30:23]==255 || b[14:7]==255) multiply=32'h7fc00000;
  else multiply=fp32_pack_from_grs(a[31]^b[15],exponent,normalized);
 end
endfunction
endmodule
