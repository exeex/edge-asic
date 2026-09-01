`timescale 1ns/1ps

module edge_actu #(
  parameter PIPE_STAGES = 20
) (
  input  wire        forever_cpuclk,
  input  wire        cpurst_b,

  input  wire        in_valid,
  input  wire        in_last,
  output wire        in_ready,
  input  wire [2:0]  in_mode,
  input  wire [31:0] in_value,
  input  wire [31:0] in_softmax_max,
  input  wire        softmax_sum_clear,

  output wire        out_valid,
  output wire [2:0]  out_mode,
  output wire [31:0] out_value,
  output wire        softmax_sum_valid,
  output wire        softmax_sum_done,
  output wire [31:0] softmax_sum_value
);

localparam [2:0] EDGE_ACTU_MODE_EXP_ONLY = 3'd0;
localparam [2:0] EDGE_ACTU_MODE_RCP_ONLY = 3'd1;
localparam [2:0] EDGE_ACTU_MODE_SIGMOID  = 3'd2;
localparam [2:0] EDGE_ACTU_MODE_SILU     = 3'd3;
localparam [2:0] EDGE_ACTU_MODE_TANH     = 3'd4;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX  = 3'd5;
localparam [2:0] EDGE_ACTU_MODE_RSQRT    = 3'd6;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX_NORMALIZE = 3'd7;
localparam integer NONLINEAR_LATENCY = 7;
localparam integer TRANSPORT_LATENCY = 6;
localparam integer BACKEND_EGRESS_LATENCY = 1;
localparam integer POST_STAGES = PIPE_STAGES - NONLINEAR_LATENCY -
                                 TRANSPORT_LATENCY -
                                 BACKEND_EGRESS_LATENCY;

wire   input_fire;
wire [31:0] exp_input_bits;
wire [31:0] neg_abs_bits;
wire [31:0] neg_abs_x2_bits;
wire [31:0] softmax_delta_bits;
wire        fused_sigmoid_like;
wire        fused_tanh_like;
wire        nonlinear_out_valid;
wire [21:0] nonlinear_out_bf22;
wire        front_valid;
wire        front_last;
wire [2:0]  front_mode;
wire [18:0] front_payload_bf19;
wire [21:0] front_primary_bf22;
wire [21:0] front_divisor_bf22;
wire        front_sum_clear;
wire        backend_sum_clear;
wire        backend_last;
wire [2:0]  aligned_mode;
wire [18:0] aligned_payload_bf19;
wire [21:0] aligned_primary_bf22;
wire        finalizer_out_valid;
wire [2:0]  finalizer_out_mode;
wire [31:0] finalizer_out_value;
wire        finalizer_sum_valid;
wire        finalizer_sum_done;
wire [31:0] finalizer_sum_value;

assign in_ready = cpurst_b;
assign input_fire = in_valid && in_ready;
assign out_valid = finalizer_out_valid;
assign out_mode = finalizer_out_mode;
assign out_value = finalizer_out_value;
assign softmax_sum_valid = finalizer_sum_valid;
assign softmax_sum_done = finalizer_sum_done;
assign softmax_sum_value = finalizer_sum_value;

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
    sig_a = (exp_a_bits == 8'b0) ? {1'b0, a_bits[22:0]} :
                                      {1'b1, a_bits[22:0]};
    sig_b = (exp_b_bits == 8'b0) ? {1'b0, b_bits[22:0]} :
                                      {1'b1, b_bits[22:0]};
    exp_a = (exp_a_bits == 8'b0) ? -12'sd126 : ({4'b0, exp_a_bits} - 12'sd127);
    exp_b = (exp_b_bits == 8'b0) ? -12'sd126 : ({4'b0, exp_b_bits} - 12'sd127);

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
        shift_amt = $signed({{20{exp_b[11]}}, exp_b}) -
                    $signed({{20{exp_a[11]}}, exp_a});
        small_sig = rshift_sticky27({sig_a, 3'b0}, shift_amt);
      end else begin
        large_sign = sign_a;
        small_sign = sign_b;
        large_exp = exp_a;
        large_sig = {sig_a, 3'b0};
        shift_amt = $signed({{20{exp_a[11]}}, exp_a}) -
                    $signed({{20{exp_b[11]}}, exp_b});
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
      end else begin
        if (large_sig == small_sig) begin
          fp32_add_bits = 32'b0;
        end else begin
          norm_sig = large_sig - small_sig;
          for (norm_count = 0; norm_count < 24; norm_count = norm_count + 1) begin
            if (!norm_sig[26] && (large_exp > -12'sd126)) begin
              norm_sig = norm_sig << 1;
              large_exp = large_exp - 12'sd1;
            end
          end
          fp32_add_bits = fp32_pack_from_grs(large_sign, large_exp, norm_sig);
        end
      end
    end
  end
endfunction

function [31:0] fp32_sub_bits;
  input [31:0] a_bits;
  input [31:0] b_bits;
  begin
    fp32_sub_bits = fp32_add_bits(a_bits, {~b_bits[31], b_bits[30:0]});
  end
endfunction

function [31:0] neg_abs_scale_bits;
  input [31:0] bits;
  input        scale_x2;
  reg [7:0] exp_bits;
  begin
    exp_bits = bits[30:23];
    if (bits[30:0] == 31'b0) begin
      neg_abs_scale_bits = 32'h8000_0000;
    end else if (scale_x2 && exp_bits < 8'hfe) begin
      neg_abs_scale_bits = {1'b1, exp_bits + 8'd1, bits[22:0]};
    end else if (scale_x2) begin
      neg_abs_scale_bits = 32'hff80_0000;
    end else begin
      neg_abs_scale_bits = {1'b1, bits[30:0]};
    end
  end
endfunction

edge_actu_exp_frontend x_exp_frontend (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(input_fire),
  .in_last(in_last),
  .in_mode(in_mode),
  .in_value(in_value),
  .in_scalar(in_softmax_max),
  .in_sum_clear(softmax_sum_clear),
  .exp_input_bits(exp_input_bits),
  .out_valid(front_valid),
  .out_last(front_last),
  .out_mode(front_mode),
  .out_payload_bf19(front_payload_bf19),
  .out_sum_clear(front_sum_clear),
  .out_primary_bf22(front_primary_bf22),
  .out_divisor_bf22(front_divisor_bf22)
);

edge_actu_rcp_backend #(.ALIGN_LATENCY(NONLINEAR_LATENCY)) x_rcp_backend (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(front_valid),
  .in_last(front_last),
  .in_mode(front_mode),
  .in_payload_bf19(front_payload_bf19),
  .in_primary_bf22(front_primary_bf22),
  .in_divisor_bf22(front_divisor_bf22),
  .in_sum_clear(front_sum_clear),
  .out_valid(nonlinear_out_valid),
  .out_last(backend_last),
  .out_mode(aligned_mode),
  .out_payload_bf19(aligned_payload_bf19),
  .out_primary_bf22(aligned_primary_bf22),
  .out_rcp_bf22(nonlinear_out_bf22),
  .out_sum_clear(backend_sum_clear)
);

assign fused_sigmoid_like = (in_mode == EDGE_ACTU_MODE_SIGMOID) ||
                            (in_mode == EDGE_ACTU_MODE_SILU);
assign fused_tanh_like = (in_mode == EDGE_ACTU_MODE_TANH);
assign neg_abs_bits = neg_abs_scale_bits(in_value, 1'b0);
assign neg_abs_x2_bits = neg_abs_scale_bits(in_value, 1'b1);
assign softmax_delta_bits = fp32_sub_bits(in_value, in_softmax_max);
assign exp_input_bits = (in_mode == EDGE_ACTU_MODE_SOFTMAX) ? softmax_delta_bits :
                        (fused_tanh_like ? neg_abs_x2_bits :
                         (fused_sigmoid_like ? neg_abs_bits : in_value));

edge_actu_finalizer #(.POST_STAGES(POST_STAGES)) x_finalizer (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(nonlinear_out_valid),
  .in_last(backend_last),
  .in_mode(aligned_mode),
  .in_payload_bf19(aligned_payload_bf19),
  .in_primary_bf22(aligned_primary_bf22),
  .in_rcp_bf22(nonlinear_out_bf22),
  .in_sum_clear(backend_sum_clear),
  .out_valid(finalizer_out_valid),
  .out_mode(finalizer_out_mode),
  .out_value(finalizer_out_value),
  .softmax_sum_valid(finalizer_sum_valid),
  .softmax_sum_done(finalizer_sum_done),
  .softmax_sum_value(finalizer_sum_value)
);

endmodule
