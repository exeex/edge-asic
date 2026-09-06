`timescale 1ns/1ps

// Bit-exact legacy ACTU FP32 subtraction. Standalone pipeline candidate;
// integration must delay the entire ACTU packet by the same number of stages.
module edge_actu_softmax_delta #(
  parameter REGISTER_ALIGN = 0
) (
  input wire clk,
  input wire cpurst_b,
  input wire in_valid,
  input wire [31:0] value_bits,
  input wire [31:0] max_bits,
  output reg out_valid,
  output reg [31:0] delta_bits
);
function [26:0] rshift_sticky27;
  input [26:0] value;
  input integer shift;
  reg sticky;
  begin
    if (shift <= 0) begin
      rshift_sticky27 = value;
    end else if (shift >= 27) begin
      rshift_sticky27 = {|value, 26'b0};
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
    if (sig_grs == 27'b0 || exp_unbiased < -12'sd126) begin
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
                              rounded[24] ? rounded[23:1] : rounded[22:0]};
    end
  end
endfunction


// Packet: bypass, bypass value, result sign, same sign, exponent, aligned sigs.
function [100:0] align_operands;
  input [31:0] a_bits, b_bits;
  reg [23:0] sig_a, sig_b;
  reg signed [11:0] exp_a, exp_b, large_exp;
  reg large_sign, small_sign, bypass;
  reg [31:0] bypass_value;
  reg [26:0] large_sig, small_sig;
  integer shift_amt;
  begin
    sig_a = {(a_bits[30:23] != 0), a_bits[22:0]};
    sig_b = {(b_bits[30:23] != 0), b_bits[22:0]};
    exp_a = a_bits[30:23] == 0 ? -12'sd126 : ({4'b0,a_bits[30:23]} - 12'sd127);
    exp_b = b_bits[30:23] == 0 ? -12'sd126 : ({4'b0,b_bits[30:23]} - 12'sd127);
    if ((exp_b > exp_a) || ((exp_b == exp_a) && (sig_b > sig_a))) begin
      large_sign = b_bits[31]; small_sign = a_bits[31]; large_exp = exp_b;
      large_sig = {sig_b,3'b0};
      shift_amt = $signed({{20{exp_b[11]}},exp_b}) - $signed({{20{exp_a[11]}},exp_a});
      small_sig = rshift_sticky27({sig_a,3'b0},shift_amt);
    end else begin
      large_sign = a_bits[31]; small_sign = b_bits[31]; large_exp = exp_a;
      large_sig = {sig_a,3'b0};
      shift_amt = $signed({{20{exp_a[11]}},exp_a}) - $signed({{20{exp_b[11]}},exp_b});
      small_sig = rshift_sticky27({sig_b,3'b0},shift_amt);
    end
    bypass = 1'b1;
    if (a_bits[30:0] == 0) bypass_value = b_bits;
    else if (b_bits[30:0] == 0) bypass_value = a_bits;
    else if (a_bits[30:23] == 8'hff || b_bits[30:23] == 8'hff)
      bypass_value = 32'h7fc00000;
    else begin bypass = 1'b0; bypass_value = 0; end
    align_operands = {bypass,bypass_value,large_sign,(large_sign == small_sign),large_exp,large_sig,small_sig};
  end
endfunction

// Packet: bypass, bypass value, sign, exponent, raw sum, normalize-left.
function [73:0] add_aligned;
  input [100:0] packet;
  reg bypass, sign_z, same_sign;
  reg [31:0] bypass_value;
  reg signed [11:0] exp_z;
  reg [26:0] large_sig, small_sig, norm_sig;
  reg [27:0] add_sig;
  begin
    {bypass,bypass_value,sign_z,same_sign,exp_z,large_sig,small_sig} = packet;
    if (same_sign) begin
      add_sig = {1'b0,large_sig} + {1'b0,small_sig};
      norm_sig = add_sig[27] ? {add_sig[27:2],|add_sig[1:0]} : add_sig[26:0];
      exp_z = exp_z + {11'b0,add_sig[27]};
    end else begin
      norm_sig = large_sig - small_sig;
      if (!bypass && large_sig == small_sig) begin
        bypass = 1'b1; bypass_value = 0;
      end
    end
    add_aligned = {bypass,bypass_value,sign_z,exp_z,norm_sig,!same_sign};
  end
endfunction

function [31:0] normalize_pack;
  input [73:0] packet;
  reg bypass, sign_z, normalize_left;
  reg [31:0] bypass_value;
  reg signed [11:0] large_exp;
  reg [26:0] norm_sig;
  begin
    {bypass,bypass_value,sign_z,large_exp,norm_sig,normalize_left} = packet;
    if (normalize_left) begin
      // Find the leading-zero count independently of the exponent budget.
          begin : normalize_lzc
            reg [26:0] probe;
            reg [4:0] count;
            reg signed [12:0] budget;
            probe = norm_sig;
            count = 0;
            if (probe[26:11] == 0) begin
              probe = probe << 16;
              count = count + 5'd16;
            end
            if (probe[26:19] == 0) begin
              probe = probe << 8;
              count = count + 5'd8;
            end
            if (probe[26:23] == 0) begin
              probe = probe << 4;
              count = count + 5'd4;
            end
            if (probe[26:25] == 0) begin
              probe = probe << 2;
              count = count + 5'd2;
            end
            if (probe[26:26] == 0) begin
              probe = probe << 1;
              count = count + 5'd1;
            end
            if (count > 24) count = 24;
            budget = $signed({large_exp[11],large_exp}) + 13'sd126;
            if (budget <= 0) count = 0;
            else if ($signed({8'b0,count}) > budget) count = budget[4:0];
            norm_sig = norm_sig << count;
            large_exp = large_exp - $signed({7'b0,count});
          end

    end
    normalize_pack = bypass ? bypass_value : fp32_pack_from_grs(sign_z,large_exp,norm_sig);
  end
endfunction

wire [100:0] aligned = align_operands(value_bits,{~max_bits[31],max_bits[30:0]});
wire [100:0] aligned_stage;
wire aligned_valid;
generate
  if (REGISTER_ALIGN) begin : g_align
    reg [100:0] packet_q;
    reg valid_q;
    always @(posedge clk) packet_q <= aligned;
    always @(posedge clk or negedge cpurst_b)
      if (!cpurst_b) valid_q <= 1'b0;
      else valid_q <= in_valid;
    assign aligned_stage = packet_q;
    assign aligned_valid = valid_q;
  end else begin : g_no_align
    assign aligned_stage = aligned;
    assign aligned_valid = in_valid;
  end
endgenerate
reg [73:0] sum_q;
reg sum_valid_q;
always @(posedge clk) begin
  sum_q <= add_aligned(aligned_stage);
  delta_bits <= normalize_pack(sum_q);
end
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    sum_valid_q <= 1'b0;
    out_valid <= 1'b0;
  end else begin
    sum_valid_q <= aligned_valid;
    out_valid <= sum_valid_q;
  end
end
endmodule
