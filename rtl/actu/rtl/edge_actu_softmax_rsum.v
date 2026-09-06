`timescale 1ns/1ps

// Positive-only BF22 softmax reduction. Four independent partial sums break
// the streaming recurrence around a four-stage adder. After the last input
// returns, the same adder drains the four-entry fall-through pipe to one sum.
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

reg [21:0] partial_q [0:3];
reg [2:0]  partial_count_q;
reg [2:0]  fill_count_q;
reg        drain_pending_q;
reg        drain_wait_q;

reg        valid_d0, valid_d1, valid_d2, valid_d3;
reg        last_d0, last_d1, last_d2, last_d3;
reg        drain_d0, drain_d1, drain_d2, drain_d3;

reg        bypass_d0;
reg [21:0] bypass_value_d0;
reg [7:0]  large_exp_d0;
reg [18:0] large_sig_d0;
reg [18:0] small_sig_d0;

reg        bypass_d1;
reg [21:0] bypass_value_d1;
reg [7:0]  large_exp_d1;
reg [19:0] sum_d1;

reg        bypass_d2;
reg [21:0] bypass_value_d2;
reg [7:0]  norm_exp_d2;
reg [18:0] norm_sig_d2;

reg [21:0] result_d3;

wire [21:0] partial_head =
    (partial_count_q == 3'd1) ? partial_q[0] :
    (partial_count_q == 3'd2) ? partial_q[1] :
    (partial_count_q == 3'd3) ? partial_q[2] : partial_q[3];
wire [21:0] partial_second =
    (partial_count_q == 3'd2) ? partial_q[0] :
    (partial_count_q == 3'd3) ? partial_q[1] : partial_q[2];

wire pipe_push = valid_d3;
wire stream_pop = in_valid_i && (fill_count_q >= 3'd4);
wire drain_launch = drain_pending_q && !drain_wait_q &&
                    (partial_count_q >= 3'd2);
wire drain_single = drain_pending_q && !drain_wait_q &&
                    (partial_count_q == 3'd1);
wire [21:0] stream_feedback = (partial_count_q != 0) ?
                              partial_head : result_d3;
wire op_valid = in_valid_i || drain_launch;
wire [21:0] op_a = drain_launch ? partial_head : in_bf22_i;
wire [21:0] op_b = drain_launch ? partial_second :
                       ((fill_count_q < 3'd4) ? 22'b0 : stream_feedback);

reg        align_bypass;
reg [21:0] align_bypass_value;
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
  align_bypass = 1'b0;
  align_bypass_value = 22'b0;
  align_large_exp = 8'b0;
  align_small_exp = 8'b0;
  align_large_sig = 19'b0;
  align_small_sig = 19'b0;
  align_sticky = 1'b0;
  align_shift = 0;
  align_small_mant = 14'b0;
  if (align_a_sig == 0) begin
    align_bypass = 1'b1;
    align_bypass_value = op_b;
  end else if (align_b_sig == 0) begin
    align_bypass = 1'b1;
    align_bypass_value = op_a;
  end else begin
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
    if (align_shift >= 19)
      align_small_sig = {18'b0,|align_small_mant};
    else if (align_shift == 0)
      align_small_sig = {align_small_mant,5'b0};
    else begin
      align_sticky = |({align_small_mant,5'b0} &
                       ((19'b1 << align_shift) - 19'b1));
      align_small_sig = ({align_small_mant,5'b0} >> align_shift) |
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
  input [21:0] bypass_value;
  input [7:0]  exp_bits;
  input [14:0] rounded;
  begin
    if (bypass)
      pack_positive_bf22 = bypass_value;
    else if ((exp_bits == 8'hff) ||
             ((exp_bits == 8'hfe) && rounded[14]))
      pack_positive_bf22 = {1'b0,8'hfe,13'h1fff};
    else if (rounded[14])
      pack_positive_bf22 = {1'b0,exp_bits + 1'b1,rounded[13:1]};
    else
      pack_positive_bf22 = {1'b0,exp_bits,rounded[12:0]};
  end
endfunction

integer slot;
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    partial_count_q <= 3'b0;
    fill_count_q <= 3'b0;
    drain_pending_q <= 1'b0;
    drain_wait_q <= 1'b0;
    out_valid_o <= 1'b0;
    out_done_o <= 1'b0;
    out_sum_bf22_o <= 22'b0;
    valid_d0 <= 1'b0; valid_d1 <= 1'b0;
    valid_d2 <= 1'b0; valid_d3 <= 1'b0;
    last_d0 <= 1'b0; last_d1 <= 1'b0;
    last_d2 <= 1'b0; last_d3 <= 1'b0;
    drain_d0 <= 1'b0; drain_d1 <= 1'b0;
    drain_d2 <= 1'b0; drain_d3 <= 1'b0;
    bypass_d0 <= 1'b0; bypass_value_d0 <= 22'b0;
    large_exp_d0 <= 8'b0; large_sig_d0 <= 19'b0; small_sig_d0 <= 19'b0;
    bypass_d1 <= 1'b0; bypass_value_d1 <= 22'b0;
    large_exp_d1 <= 8'b0; sum_d1 <= 20'b0;
    bypass_d2 <= 1'b0; bypass_value_d2 <= 22'b0;
    norm_exp_d2 <= 8'b0; norm_sig_d2 <= 19'b0;
    result_d3 <= 22'b0;
    for (slot = 0; slot < 4; slot = slot + 1)
      partial_q[slot] <= 22'b0;
  end else if (clear_i) begin
    partial_count_q <= 3'b0;
    fill_count_q <= 3'b0;
    drain_pending_q <= 1'b0;
    drain_wait_q <= 1'b0;
    out_valid_o <= 1'b0;
    out_done_o <= 1'b0;
    out_sum_bf22_o <= 22'b0;
    valid_d0 <= 1'b0; valid_d1 <= 1'b0;
    valid_d2 <= 1'b0; valid_d3 <= 1'b0;
    last_d0 <= 1'b0; last_d1 <= 1'b0;
    last_d2 <= 1'b0; last_d3 <= 1'b0;
    drain_d0 <= 1'b0; drain_d1 <= 1'b0;
    drain_d2 <= 1'b0; drain_d3 <= 1'b0;
    for (slot = 0; slot < 4; slot = slot + 1)
      partial_q[slot] <= 22'b0;
  end else begin
    out_valid_o <= 1'b0;

    valid_d0 <= op_valid;
    last_d0 <= in_valid_i && in_last_i;
    drain_d0 <= drain_launch;
    if (op_valid) begin
      bypass_d0 <= align_bypass;
      bypass_value_d0 <= align_bypass_value;
      large_exp_d0 <= align_large_exp;
      large_sig_d0 <= align_large_sig;
      small_sig_d0 <= align_small_sig;
    end

    valid_d1 <= valid_d0;
    last_d1 <= last_d0;
    drain_d1 <= drain_d0;
    if (valid_d0) begin
      bypass_d1 <= bypass_d0;
      bypass_value_d1 <= bypass_value_d0;
      large_exp_d1 <= large_exp_d0;
      sum_d1 <= {1'b0,large_sig_d0} + {1'b0,small_sig_d0};
    end

    valid_d2 <= valid_d1;
    last_d2 <= last_d1;
    drain_d2 <= drain_d1;
    if (valid_d1) begin
      bypass_d2 <= bypass_d1;
      bypass_value_d2 <= bypass_value_d1;
      norm_exp_d2 <= normalized_exp;
      norm_sig_d2 <= normalized_sig;
    end

    valid_d3 <= valid_d2;
    last_d3 <= last_d2;
    drain_d3 <= drain_d2;
    if (valid_d2)
      result_d3 <= pack_positive_bf22(
          bypass_d2,bypass_value_d2,norm_exp_d2,rounded_value);

    if (in_valid_i && fill_count_q < 3'd4)
      fill_count_q <= fill_count_q + 1'b1;

    if (pipe_push) begin
      partial_q[0] <= result_d3;
      partial_q[1] <= partial_q[0];
      partial_q[2] <= partial_q[1];
      partial_q[3] <= partial_q[2];
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
    $display("ACTU softmax RSUM accepted input during drain");
    $finish;
  end
  if (cpurst_b && !clear_i && partial_count_q > 4) begin
    $display("ACTU softmax RSUM partial pipe overflow");
    $finish;
  end
end
`endif

endmodule
