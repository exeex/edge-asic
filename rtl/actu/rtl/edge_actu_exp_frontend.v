`timescale 1ns/1ps

// West-side ACTU frontend. EXP and the fused native-BF22 numerator /
// denominator transform stay behind a registered physical boundary.
(* keep_hierarchy = "yes" *)
module edge_actu_exp_frontend (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire        in_last,
  input  wire [2:0]  in_mode,
  input  wire [31:0] in_value,
  input  wire [31:0] in_scalar,
  input  wire        in_sum_clear,
  input  wire [31:0] exp_input_bits,
  output reg         out_valid,
  output reg         out_last,
  output reg  [2:0]  out_mode,
  output reg  [18:0] out_payload_bf19,
  output reg         out_sum_clear,
  output reg  [21:0] out_primary_bf22,
  output reg  [21:0] out_divisor_bf22
);

localparam [2:0] EDGE_ACTU_MODE_RCP_ONLY = 3'd1;
localparam [2:0] EDGE_ACTU_MODE_SIGMOID = 3'd2;
localparam [2:0] EDGE_ACTU_MODE_SILU = 3'd3;
localparam [2:0] EDGE_ACTU_MODE_TANH = 3'd4;
localparam [2:0] EDGE_ACTU_MODE_RSQRT = 3'd6;
localparam [2:0] EDGE_ACTU_MODE_SOFTMAX_NORMALIZE = 3'd7;
localparam [21:0] BF22_ONE = 22'h0fe000;
localparam [18:0] BF22_ONE_EXT = {14'h2000, 5'b0};

wire [31:0] exp_lut_bits;
wire [21:0] exp_lut_bf22;
wire [18:0] aligned_e_s1;
wire [19:0] den_raw_s1;
wire [18:0] tanh_num_raw_s1;
wire [4:0] tanh_num_lzc_s2;
wire [21:0] den_bf22_s2;
wire [21:0] tanh_num_bf22_s3;
wire [21:0] bypass_add_bf22_s2;
wire fused_sigmoid_s3;

reg         valid_s0;
reg         last_s0;
reg [2:0]   mode_s0;
reg [18:0]  payload_bf19_s0;
reg         sum_clear_s0;
reg [21:0]  exp_s0;
reg [21:0]  value_bf22_s0;
reg [21:0]  scalar_bf22_s0;

reg         valid_s1;
reg         last_s1;
reg [2:0]   mode_s1;
reg [18:0]  payload_bf19_s1;
reg         sum_clear_s1;
reg [21:0]  exp_s1;
reg [21:0]  value_bf22_s1;
reg [21:0]  scalar_bf22_s1;
reg [19:0]  den_raw_s1_q;
reg [18:0]  tanh_num_raw_s1_q;
reg [7:0]   bypass_add_exp_s1_q;
reg [19:0]  bypass_add_raw_s1_q;

reg         valid_s2;
reg         last_s2;
reg [2:0]   mode_s2;
reg [18:0]  payload_bf19_s2;
reg         sum_clear_s2;
reg [21:0]  exp_s2;
reg [21:0]  value_bf22_s2;
reg [21:0]  scalar_bf22_s2;
reg [21:0]  den_s2;
reg [21:0]  bypass_add_s2;
reg [18:0]  tanh_num_raw_s2;
reg [4:0]   tanh_num_lzc_s2_q;

reg [7:0]   bypass_large_exp;
reg [7:0]   bypass_small_exp;
reg [13:0]  bypass_large_sig;
reg [13:0]  bypass_small_sig;
reg [18:0]  bypass_large_ext;
reg [18:0]  bypass_small_ext;
reg         bypass_sticky;
reg [19:0]  bypass_add_raw_s1;
reg [7:0]   bypass_add_exp_s1;
integer     bypass_shift;

function [21:0] bf22_round_native;
  input [31:0] bits;
  reg [21:0] main;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      bf22_round_native = 22'h1ff000;
    end else begin
      main = bits[31:10];
      bf22_round_native = main +
                          (bits[9] && (|bits[8:0] || main[0]));
    end
  end
endfunction

function [18:0] bf19_round_native;
  input [31:0] bits;
  reg [18:0] main;
  begin
    if ((bits[30:23] == 8'hff) && (bits[22:0] != 23'b0)) begin
      bf19_round_native = 19'h3fc00;
    end else begin
      main = bits[31:13];
      bf19_round_native = main +
                          (bits[12] && (|bits[11:0] || main[0]));
    end
  end
endfunction

// Align positive BF22 e to the 1.0 exponent with five GRS bits. Fused modes
// guarantee 0 <= e <= 1; values above one are clamped to the exact-one rail.
function [18:0] align_to_one_grs;
  input [21:0] e;
  reg [7:0] exp_bits;
  reg [13:0] sig;
  reg [18:0] ext;
  reg sticky;
  integer shift;
  begin
    exp_bits = e[20:13];
    sig = (exp_bits == 0) ? {1'b0, e[12:0]} : {1'b1, e[12:0]};
    ext = {sig, 5'b0};
    if (sig == 0) begin
      align_to_one_grs = 19'b0;
    end else if (exp_bits >= 8'd127) begin
      align_to_one_grs = BF22_ONE_EXT;
    end else begin
      shift = {24'b0, 8'd127} - {24'b0, exp_bits};
      if (shift >= 19) begin
        align_to_one_grs = {18'b0, |sig};
      end else begin
        sticky = |(ext & ((19'b1 << shift) - 19'b1));
        align_to_one_grs = (ext >> shift) | {18'b0, sticky};
      end
    end
  end
endfunction

function [4:0] lzc19;
  input [18:0] value;
  begin
    casez (value)
      19'b1??????????????????: lzc19 = 5'd0;
      19'b01?????????????????: lzc19 = 5'd1;
      19'b001????????????????: lzc19 = 5'd2;
      19'b0001???????????????: lzc19 = 5'd3;
      19'b00001??????????????: lzc19 = 5'd4;
      19'b000001?????????????: lzc19 = 5'd5;
      19'b0000001????????????: lzc19 = 5'd6;
      19'b00000001???????????: lzc19 = 5'd7;
      19'b000000001??????????: lzc19 = 5'd8;
      19'b0000000001?????????: lzc19 = 5'd9;
      19'b00000000001????????: lzc19 = 5'd10;
      19'b000000000001???????: lzc19 = 5'd11;
      19'b0000000000001??????: lzc19 = 5'd12;
      19'b00000000000001?????: lzc19 = 5'd13;
      19'b000000000000001????: lzc19 = 5'd14;
      19'b0000000000000001???: lzc19 = 5'd15;
      19'b00000000000000001??: lzc19 = 5'd16;
      19'b000000000000000001?: lzc19 = 5'd17;
      19'b0000000000000000001: lzc19 = 5'd18;
      default: lzc19 = 5'd19;
    endcase
  end
endfunction

function [21:0] pack_den_bf22;
  input [19:0] raw;
  reg [7:0] exp_bits;
  reg [18:0] norm;
  reg [13:0] main;
  reg [14:0] rounded;
  begin
    if (raw[19]) begin
      exp_bits = 8'd128;
      norm = {raw[19:2], |raw[1:0]};
    end else begin
      exp_bits = 8'd127;
      norm = raw[18:0];
    end
    main = norm[18:5];
    rounded = {1'b0, main} +
              (norm[4] && (|norm[3:0] || main[0]));
    if (rounded[14])
      pack_den_bf22 = {1'b0, exp_bits + 1'b1, rounded[13:1]};
    else
      pack_den_bf22 = {1'b0, exp_bits, rounded[12:0]};
  end
endfunction

function [21:0] pack_num_bf22;
  input [18:0] raw;
  input [4:0] leading_zeros;
  reg [18:0] norm;
  reg [13:0] main;
  reg [14:0] rounded;
  reg [7:0] exp_bits;
  begin
    if (raw == 0 || leading_zeros >= 5'd19) begin
      pack_num_bf22 = 22'b0;
    end else begin
      norm = raw << leading_zeros;
      exp_bits = 8'd127 - {3'b0, leading_zeros};
      main = norm[18:5];
      rounded = {1'b0, main} +
                (norm[4] && (|norm[3:0] || main[0]));
      if (rounded[14])
        pack_num_bf22 = {1'b0, exp_bits + 1'b1, rounded[13:1]};
      else
        pack_num_bf22 = {1'b0, exp_bits, rounded[12:0]};
    end
  end
endfunction

function [21:0] pack_positive_add_bf22;
  input [19:0] raw;
  input [7:0] base_exp;
  reg [7:0] exp_bits;
  reg [18:0] norm;
  reg [13:0] main;
  reg [14:0] rounded;
  begin
    if (raw == 0) begin
      pack_positive_add_bf22 = 22'b0;
    end else begin
      if (raw[19]) begin
        exp_bits = base_exp + 1'b1;
        norm = {raw[19:2], |raw[1:0]};
      end else begin
        exp_bits = base_exp;
        norm = raw[18:0];
      end
      main = norm[18:5];
      rounded = {1'b0, main} +
                (norm[4] && (|norm[3:0] || main[0]));
      if (exp_bits == 8'hff ||
          (exp_bits == 8'hfe && rounded[14]))
        pack_positive_add_bf22 = 22'h1fdfff;
      else if (rounded[14])
        pack_positive_add_bf22 = {1'b0, exp_bits + 1'b1,
                                  rounded[13:1]};
      else
        pack_positive_add_bf22 = {1'b0, exp_bits, rounded[12:0]};
    end
  end
endfunction

// Direct RSQRT uses positive x+epsilon. Perform only alignment/addition here;
// F2 owns normalization and RNE packing so no generic FP32 adder crosses the
// frontend/backend boundary.
always @* begin
  if ((scalar_bf22_s0[20:13] > value_bf22_s0[20:13]) ||
      ((scalar_bf22_s0[20:13] == value_bf22_s0[20:13]) &&
       (scalar_bf22_s0[12:0] > value_bf22_s0[12:0]))) begin
    bypass_large_exp = (scalar_bf22_s0[20:13] == 0) ?
                       8'd1 : scalar_bf22_s0[20:13];
    bypass_small_exp = (value_bf22_s0[20:13] == 0) ?
                       8'd1 : value_bf22_s0[20:13];
    bypass_large_sig = (scalar_bf22_s0[20:13] == 0) ?
                       {1'b0, scalar_bf22_s0[12:0]} :
                       {1'b1, scalar_bf22_s0[12:0]};
    bypass_small_sig = (value_bf22_s0[20:13] == 0) ?
                       {1'b0, value_bf22_s0[12:0]} :
                       {1'b1, value_bf22_s0[12:0]};
  end else begin
    bypass_large_exp = (value_bf22_s0[20:13] == 0) ?
                       8'd1 : value_bf22_s0[20:13];
    bypass_small_exp = (scalar_bf22_s0[20:13] == 0) ?
                       8'd1 : scalar_bf22_s0[20:13];
    bypass_large_sig = (value_bf22_s0[20:13] == 0) ?
                       {1'b0, value_bf22_s0[12:0]} :
                       {1'b1, value_bf22_s0[12:0]};
    bypass_small_sig = (scalar_bf22_s0[20:13] == 0) ?
                       {1'b0, scalar_bf22_s0[12:0]} :
                       {1'b1, scalar_bf22_s0[12:0]};
  end
  bypass_large_ext = {bypass_large_sig, 5'b0};
  bypass_small_ext = {bypass_small_sig, 5'b0};
  bypass_shift = {24'b0, bypass_large_exp} -
                 {24'b0, bypass_small_exp};
  bypass_sticky = 1'b0;
  if (bypass_shift >= 19) begin
    bypass_small_ext = {18'b0, |bypass_small_sig};
  end else if (bypass_shift != 0) begin
    bypass_sticky = |(bypass_small_ext &
                      ((19'b1 << bypass_shift) - 19'b1));
    bypass_small_ext = (bypass_small_ext >> bypass_shift) |
                       {18'b0, bypass_sticky};
  end
  bypass_add_exp_s1 = bypass_large_exp;
  bypass_add_raw_s1 = {1'b0, bypass_large_ext} +
                      {1'b0, bypass_small_ext};
end

edge_actu_exp_lut2base_split x_exp_lut (
  .value_bits(exp_input_bits),
  .exp_bits(exp_lut_bits)
);

assign exp_lut_bf22 = bf22_round_native(exp_lut_bits);
assign aligned_e_s1 = align_to_one_grs(exp_s0);
assign den_raw_s1 = {1'b0, BF22_ONE_EXT} + {1'b0, aligned_e_s1};
assign tanh_num_raw_s1 = (aligned_e_s1 >= BF22_ONE_EXT) ? 19'b0 :
                         (BF22_ONE_EXT - aligned_e_s1);
assign tanh_num_lzc_s2 = lzc19(tanh_num_raw_s1_q);
assign den_bf22_s2 = pack_den_bf22(den_raw_s1_q);
assign bypass_add_bf22_s2 = pack_positive_add_bf22(
                              bypass_add_raw_s1_q,
                              bypass_add_exp_s1_q);
assign tanh_num_bf22_s3 = pack_num_bf22(tanh_num_raw_s2,
                                        tanh_num_lzc_s2_q);
assign fused_sigmoid_s3 = (mode_s2 == EDGE_ACTU_MODE_SIGMOID) ||
                           (mode_s2 == EDGE_ACTU_MODE_SILU);

always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    valid_s0 <= 1'b0;
    last_s0 <= 1'b0;
    mode_s0 <= 3'b0;
    payload_bf19_s0 <= 19'b0;
    sum_clear_s0 <= 1'b0;
    exp_s0 <= 22'b0;
    value_bf22_s0 <= 22'b0;
    scalar_bf22_s0 <= 22'b0;
    valid_s1 <= 1'b0;
    last_s1 <= 1'b0;
    mode_s1 <= 3'b0;
    payload_bf19_s1 <= 19'b0;
    sum_clear_s1 <= 1'b0;
    exp_s1 <= 22'b0;
    value_bf22_s1 <= 22'b0;
    scalar_bf22_s1 <= 22'b0;
    den_raw_s1_q <= 20'b0;
    tanh_num_raw_s1_q <= 19'b0;
    bypass_add_exp_s1_q <= 8'b0;
    bypass_add_raw_s1_q <= 20'b0;
    valid_s2 <= 1'b0;
    last_s2 <= 1'b0;
    mode_s2 <= 3'b0;
    payload_bf19_s2 <= 19'b0;
    sum_clear_s2 <= 1'b0;
    exp_s2 <= 22'b0;
    value_bf22_s2 <= 22'b0;
    scalar_bf22_s2 <= 22'b0;
    den_s2 <= 22'b0;
    bypass_add_s2 <= 22'b0;
    tanh_num_raw_s2 <= 19'b0;
    tanh_num_lzc_s2_q <= 5'b0;
    out_valid <= 1'b0;
    out_last <= 1'b0;
    out_mode <= 3'b0;
    out_payload_bf19 <= 19'b0;
    out_sum_clear <= 1'b0;
    out_primary_bf22 <= 22'b0;
    out_divisor_bf22 <= 22'b0;
  end else begin
    // F0: EXP output boundary.
    valid_s0 <= in_valid;
    last_s0 <= in_last;
    mode_s0 <= in_mode;
    payload_bf19_s0 <= bf19_round_native(in_value);
    sum_clear_s0 <= in_sum_clear;
    exp_s0 <= exp_lut_bf22;
    value_bf22_s0 <= bf22_round_native(in_value);
    scalar_bf22_s0 <= bf22_round_native(in_scalar);

    // F1: shared alignment and parallel 1+e / 1-e raw arithmetic.
    valid_s1 <= valid_s0;
    last_s1 <= last_s0;
    mode_s1 <= mode_s0;
    payload_bf19_s1 <= payload_bf19_s0;
    sum_clear_s1 <= sum_clear_s0;
    exp_s1 <= exp_s0;
    value_bf22_s1 <= value_bf22_s0;
    scalar_bf22_s1 <= scalar_bf22_s0;
    den_raw_s1_q <= den_raw_s1;
    tanh_num_raw_s1_q <= tanh_num_raw_s1;
    bypass_add_exp_s1_q <= bypass_add_exp_s1;
    bypass_add_raw_s1_q <= bypass_add_raw_s1;

    // F2: denominator pack and numerator leading-zero detection.
    valid_s2 <= valid_s1;
    last_s2 <= last_s1;
    mode_s2 <= mode_s1;
    payload_bf19_s2 <= payload_bf19_s1;
    sum_clear_s2 <= sum_clear_s1;
    exp_s2 <= exp_s1;
    value_bf22_s2 <= value_bf22_s1;
    scalar_bf22_s2 <= scalar_bf22_s1;
    den_s2 <= den_bf22_s2;
    bypass_add_s2 <= bypass_add_bf22_s2;
    tanh_num_raw_s2 <= tanh_num_raw_s1_q;
    tanh_num_lzc_s2_q <= tanh_num_lzc_s2;

    // F3: numerator normalize/pack and native-BF22 frontend packet.
    out_valid <= valid_s2;
    out_last <= last_s2;
    out_mode <= mode_s2;
    out_payload_bf19 <= payload_bf19_s2;
    out_sum_clear <= sum_clear_s2;
    if (mode_s2 == EDGE_ACTU_MODE_RCP_ONLY)
      out_divisor_bf22 <= value_bf22_s2;
    else if (mode_s2 == EDGE_ACTU_MODE_RSQRT)
      // RSQRT's architectural domain is non-negative. Preserve a negative
      // source so the shared backend returns its invalid/zero result instead
      // of interpreting the magnitude as a positive operand.
      out_divisor_bf22 <= value_bf22_s2[21] ? value_bf22_s2 : bypass_add_s2;
    else if (mode_s2 == EDGE_ACTU_MODE_SOFTMAX_NORMALIZE)
      out_divisor_bf22 <= scalar_bf22_s2;
    else
      out_divisor_bf22 <= den_s2;
    if (mode_s2 == EDGE_ACTU_MODE_TANH)
      out_primary_bf22 <= tanh_num_bf22_s3;
    else if (fused_sigmoid_s3)
      out_primary_bf22 <= payload_bf19_s2[18] ? exp_s2 : BF22_ONE;
    else
      out_primary_bf22 <= exp_s2;
  end
end

endmodule
