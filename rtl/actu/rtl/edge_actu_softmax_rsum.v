`timescale 1ns/1ps

// Positive-only BF22 softmax reduction. Five independent partial sums break
// the streaming recurrence around a five-stage adder. After the last input
// returns, the same adder drains the five-entry fall-through pipe to one sum.
module edge_actu_softmax_rsum (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        clear_i,
  input  wire        in_valid_i,
  input  wire        in_last_i,
  input  wire [21:0] in_bf22_i,
  output reg         out_valid_o,
  output reg         out_done_o,
  output reg  [21:0] out_sum_bf22_o
);

reg [21:0] partial_q [0:4];
reg [2:0]  partial_count_q;
reg [2:0]  fill_count_q;
reg        drain_pending_q;
reg        drain_wait_q;

reg        valid_d0, valid_d1, valid_d2, valid_d3;
reg        last_d0, last_d1, last_d2, last_d3;
reg        drain_d0, drain_d1, drain_d2, drain_d3;

// Prepare exponent difference before the variable alignment shifter.
reg valid_pre, last_pre, drain_pre;
reg bypass_pre;
reg bypass_sign_pre, bypass_expzero_pre;
reg [7:0] large_exp_pre, shift_pre;
reg [18:0] large_sig_pre;
reg [13:0] small_mant_pre;

reg        bypass_d0;
reg bypass_sign_d0, bypass_expzero_d0;
reg [7:0]  large_exp_d0;
reg [18:0] large_sig_d0;
reg [18:0] small_sig_d0;

reg        bypass_d1;
reg bypass_sign_d1, bypass_expzero_d1;
reg [7:0]  large_exp_d1;
reg [19:0] sum_d1;

reg        bypass_d2;
reg bypass_sign_d2, bypass_expzero_d2;
reg [7:0]  norm_exp_d2;
reg [18:0] norm_sig_d2;

reg [21:0] result_d3;

wire [21:0] partial_head =
    (partial_count_q == 3'd1) ? partial_q[0] :
    (partial_count_q == 3'd2) ? partial_q[1] :
    (partial_count_q == 3'd3) ? partial_q[2] :
    (partial_count_q == 3'd4) ? partial_q[3] : partial_q[4];
wire [21:0] partial_second =
    (partial_count_q == 3'd2) ? partial_q[0] :
    (partial_count_q == 3'd3) ? partial_q[1] :
    (partial_count_q == 3'd4) ? partial_q[2] : partial_q[3];

wire pipe_push = valid_d3;
wire stream_pop = in_valid_i && (fill_count_q >= 3'd5);
wire drain_launch = drain_pending_q && !drain_wait_q &&
                    (partial_count_q >= 3'd2);
wire drain_single = drain_pending_q && !drain_wait_q &&
                    (partial_count_q == 3'd1);
wire [21:0] stream_feedback = (partial_count_q != 0) ?
                              partial_head : result_d3;
wire op_valid = in_valid_i || drain_launch;
wire [21:0] op_a = drain_launch ? partial_head : in_bf22_i;
wire [21:0] op_b = drain_launch ? partial_second :
                       ((fill_count_q < 3'd5) ? 22'b0 : stream_feedback);

reg        align_bypass;
reg align_bypass_sign, align_bypass_expzero;
reg [7:0]  align_large_exp;
reg [7:0]  align_small_exp;
reg [13:0] align_a_sig;
reg [13:0] align_b_sig;
reg [18:0] align_large_sig;
reg [18:0] align_small_sig;
reg        align_sticky;
reg [7:0]  align_shift;
reg [13:0] align_small_mant;

reg [18:0] normalized_sig;
reg [7:0]  normalized_exp;
reg [13:0] rounded_main;
reg [14:0] rounded_value;

always @* begin
  align_a_sig = (op_a[20:13] == 0) ? {1'b0,op_a[12:0]} :
                                             {1'b1,op_a[12:0]};
  align_b_sig = (op_b[20:13] == 0) ? {1'b0,op_b[12:0]} :
                                             {1'b1,op_b[12:0]};
  // Zero operands still traverse the ordinary align/add/RNE datapath.
  // Preserve only the original sign and exponent-zero pack semantics.
  align_bypass = (align_a_sig==0)||(align_b_sig==0);
  align_bypass_sign = (align_a_sig==0)?op_b[21]:op_a[21];
  align_bypass_expzero = (align_a_sig==0)?(op_b[20:13]==0):(op_a[20:13]==0);
  begin
    // Equal exponents require no alignment: positive addition is commutative.
    // Select the operands first so both orders share one sticky shifter.
    if (op_b[20:13] > op_a[20:13]) begin
      align_large_exp = (op_b[20:13] == 0) ? 8'd1 : op_b[20:13];
      align_small_exp = (op_a[20:13] == 0) ? 8'd1 : op_a[20:13];
      align_large_sig = {align_b_sig,5'b0};
      align_small_mant = align_a_sig;
    end else begin
      align_large_exp = (op_a[20:13] == 0) ? 8'd1 : op_a[20:13];
      align_small_exp = (op_b[20:13] == 0) ? 8'd1 : op_b[20:13];
      align_large_sig = {align_a_sig,5'b0};
      align_small_mant = align_b_sig;
    end
    align_shift = align_large_exp - align_small_exp;
  end
end

always @* begin
  align_sticky = 1'b0;
  align_small_sig = 19'b0;
  begin // Alignment runs regardless of zero-operand metadata.
    if (shift_pre >= 19)
      align_small_sig = {18'b0,|small_mant_pre};
    else if (shift_pre == 0)
      align_small_sig = {small_mant_pre,5'b0};
    else begin
      align_sticky = |({small_mant_pre,5'b0} &
                       ((19'b1 << shift_pre) - 19'b1));
      align_small_sig = ({small_mant_pre,5'b0} >> shift_pre) |
                        {18'b0,align_sticky};
    end
  end
end

always @* begin
  normalized_exp = large_exp_d1;
  if (sum_d1[19]) begin
    normalized_sig = {sum_d1[19:2],|sum_d1[1:0]};
    normalized_exp = large_exp_d1 + 1'b1;
  end else begin
    normalized_sig = sum_d1[18:0];
  end
end

always @* begin
  rounded_main = norm_sig_d2[18:5];
  rounded_value = {1'b0,rounded_main} +
                  (norm_sig_d2[4] &&
                   (|norm_sig_d2[3:0] || rounded_main[0]));
end

function [21:0] pack_positive_bf22;
  input        bypass;
  input bypass_sign;
  input bypass_expzero;
  input [7:0]  exp_bits;
  input [14:0] rounded;
  begin
    if (bypass)
      pack_positive_bf22 = {bypass_sign, (bypass_expzero?8'b0:exp_bits), rounded[12:0]};
    else if ((exp_bits == 8'hff) ||
             ((exp_bits == 8'hfe) && rounded[14]))
      pack_positive_bf22 = {1'b0,8'hfe,13'h1fff};
    else if (rounded[14])
      pack_positive_bf22 = {1'b0,exp_bits + 1'b1,rounded[13:1]};
    else
      pack_positive_bf22 = {1'b0,exp_bits,rounded[12:0]};
  end
endfunction

// Arithmetic packets have no reset/clear dependency. Reset/clear cancel their
// valid tags; accumulator state and externally visible outputs still reset.
// Preserve result holding between valid operations for the feedback bypass.
always @(posedge clk) begin
    if (op_valid) begin
      bypass_pre <= align_bypass;
      bypass_sign_pre <= align_bypass_sign;
      bypass_expzero_pre <= align_bypass_expzero;
      large_exp_pre <= align_large_exp;
      large_sig_pre <= align_large_sig;
      shift_pre <= align_shift;
      small_mant_pre <= align_small_mant;
    end
    if (valid_pre) begin
      bypass_d0 <= bypass_pre;
      bypass_sign_d0 <= bypass_sign_pre;
      bypass_expzero_d0 <= bypass_expzero_pre;
      large_exp_d0 <= large_exp_pre;
      large_sig_d0 <= large_sig_pre;
      small_sig_d0 <= align_small_sig;
    end
    if (valid_d0) begin
      bypass_d1 <= bypass_d0;
      bypass_sign_d1 <= bypass_sign_d0;
      bypass_expzero_d1 <= bypass_expzero_d0;
      large_exp_d1 <= large_exp_d0;
      sum_d1 <= {1'b0,large_sig_d0} + {1'b0,small_sig_d0};
    end
    if (valid_d1) begin
      bypass_d2 <= bypass_d1;
      bypass_sign_d2 <= bypass_sign_d1;
      bypass_expzero_d2 <= bypass_expzero_d1;
      norm_exp_d2 <= normalized_exp;
      norm_sig_d2 <= normalized_sig;
    end
    if (valid_d2)
      result_d3 <= pack_positive_bf22(
          bypass_d2,bypass_sign_d2,bypass_expzero_d2,norm_exp_d2,rounded_value);
end

// Queue payload is meaningful only within partial_count_q. Reset/clear
// empty the queue by resetting its count; refill overwrites valid entries.
always @(posedge clk) begin
  if (pipe_push) begin
    partial_q[0] <= result_d3;
    partial_q[1] <= partial_q[0];
    partial_q[2] <= partial_q[1];
    partial_q[3] <= partial_q[2];
    partial_q[4] <= partial_q[3];
  end
end

always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    partial_count_q <= 3'b0;
    fill_count_q <= 3'b0;
    drain_pending_q <= 1'b0;
    drain_wait_q <= 1'b0;
    out_valid_o <= 1'b0;
    out_done_o <= 1'b0;
    out_sum_bf22_o <= 22'b0;
    valid_pre <= 1'b0; last_pre <= 1'b0; drain_pre <= 1'b0;
    valid_d0 <= 1'b0; valid_d1 <= 1'b0;
    valid_d2 <= 1'b0; valid_d3 <= 1'b0;
    last_d0 <= 1'b0; last_d1 <= 1'b0;
    last_d2 <= 1'b0; last_d3 <= 1'b0;
    drain_d0 <= 1'b0; drain_d1 <= 1'b0;
    drain_d2 <= 1'b0; drain_d3 <= 1'b0;
  end else if (clear_i) begin
    partial_count_q <= 3'b0;
    fill_count_q <= 3'b0;
    drain_pending_q <= 1'b0;
    drain_wait_q <= 1'b0;
    out_valid_o <= 1'b0;
    out_done_o <= 1'b0;
    out_sum_bf22_o <= 22'b0;
    valid_pre <= 1'b0; last_pre <= 1'b0; drain_pre <= 1'b0;
    valid_d0 <= 1'b0; valid_d1 <= 1'b0;
    valid_d2 <= 1'b0; valid_d3 <= 1'b0;
    last_d0 <= 1'b0; last_d1 <= 1'b0;
    last_d2 <= 1'b0; last_d3 <= 1'b0;
    drain_d0 <= 1'b0; drain_d1 <= 1'b0;
    drain_d2 <= 1'b0; drain_d3 <= 1'b0;
  end else begin
    out_valid_o <= 1'b0;

    valid_pre <= op_valid;
    last_pre <= in_valid_i && in_last_i;
    drain_pre <= drain_launch;
    valid_d0 <= valid_pre;
    last_d0 <= last_pre;
    drain_d0 <= drain_pre;

    valid_d1 <= valid_d0;
    last_d1 <= last_d0;
    drain_d1 <= drain_d0;

    valid_d2 <= valid_d1;
    last_d2 <= last_d1;
    drain_d2 <= drain_d1;

    valid_d3 <= valid_d2;
    last_d3 <= last_d2;
    drain_d3 <= drain_d2;

    if (in_valid_i && fill_count_q < 3'd5)
      fill_count_q <= fill_count_q + 1'b1;

    if (pipe_push) begin
      if (last_d3)
        drain_pending_q <= 1'b1;
      if (drain_d3)
        drain_wait_q <= 1'b0;
    end

    if (drain_launch)
      drain_wait_q <= 1'b1;

    if (drain_single) begin
      out_sum_bf22_o <= partial_head;
      out_valid_o <= 1'b1;
      out_done_o <= 1'b1;
      drain_pending_q <= 1'b0;
      partial_count_q <= 3'b0;
    end else if (drain_launch) begin
      partial_count_q <= partial_count_q - 3'd2;
    end else begin
      case ({pipe_push,stream_pop})
        2'b10: partial_count_q <= partial_count_q + 1'b1;
        2'b01: partial_count_q <= partial_count_q - 1'b1;
        default: partial_count_q <= partial_count_q;
      endcase
    end
  end
end

`ifndef SYNTHESIS
always @(posedge clk) begin
  if (cpurst_b && !clear_i && in_valid_i && drain_pending_q) begin
    $fatal(1,"ACTU softmax RSUM accepted input during drain");
  end
  if (cpurst_b && !clear_i && partial_count_q > 5) begin
    $fatal(1,"ACTU softmax RSUM partial pipe overflow");
  end
end
`endif

endmodule
