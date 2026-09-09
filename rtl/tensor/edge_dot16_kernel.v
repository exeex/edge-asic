// E4 dot16 row: sixteen local weight leaves around one central exponent
// metadata double buffer, exp-max circuit, and signed reduction tree.
module edge_dot16_kernel #(
  parameter LOCAL_WEIGHT_BUFFER = 0,
  parameter ROW_INDEX = 0,
  parameter TRACK_VALID = 1,
  parameter FPGA_DSP_MUL = 0
)(
  clk, rst_b, in_valid,rsum_enable_i,rsum_first_i,rsum_last_i,
  bf16_vec_lo_i, bf16_vec_hi_i,
  int8_vec_lo_i, int8_vec_hi_i,
  weight_bf16_mode_i,
  bf16_weight_vec_lo_i, bf16_weight_vec_hi_i,
  weight_fill_valid_i,weight_fill_ready_o,weight_fill_data_i,
  weight_activate_i,
  out_valid, bf20_o
);

input          clk;
input          rst_b;
input          in_valid;
input          rsum_enable_i,rsum_first_i,rsum_last_i;
input  [127:0] bf16_vec_lo_i;
input  [127:0] bf16_vec_hi_i;
input  [63:0]  int8_vec_lo_i;
input  [63:0]  int8_vec_hi_i;
input          weight_bf16_mode_i;
input  [127:0] bf16_weight_vec_lo_i;
input  [127:0] bf16_weight_vec_hi_i;
input          weight_fill_valid_i;
output         weight_fill_ready_o;
input  [15:0]  weight_fill_data_i;
input          weight_activate_i;
output         out_valid;
output [19:0]  bf20_o;


wire signed [22:0] dot16_partial_sum;
wire signed [9:0] dot16_partial_exp;
reg weight_active_bank_q;
wire [255:0] local_selected_weight;
wire [255:0] activation_vec = {bf16_vec_hi_i,bf16_vec_lo_i};
wire kernel_weight_bf16_mode = LOCAL_WEIGHT_BUFFER
  ? 1'b1 : weight_bf16_mode_i;
wire [255:0] direct_weight = {bf16_weight_vec_hi_i,bf16_weight_vec_lo_i};
wire [255:0] selected_weight = LOCAL_WEIGHT_BUFFER
  ? local_selected_weight : direct_weight;
wire [127:0] selected_weight_lo = selected_weight[127:0];
wire [127:0] selected_weight_hi = selected_weight[255:128];
reg [127:0] weight_exp_bank0_q;
reg [127:0] weight_exp_bank1_q;
wire [127:0] selected_weight_exp = weight_active_bank_q
  ? weight_exp_bank1_q : weight_exp_bank0_q;
reg [3:0] weight_fill_count_q;
reg weight_pending_q;
wire weight_fill_fire = LOCAL_WEIGHT_BUFFER && weight_fill_valid_i && weight_fill_ready_o;
assign weight_fill_ready_o = rst_b && !weight_pending_q;
reg weight_fill_bf16_q;
wire fill_bf16_mode = (weight_fill_count_q == 0)
  ? weight_bf16_mode_i : weight_fill_bf16_q;
wire [16:0] converted_weight = convert_weight(weight_fill_data_i,fill_bf16_mode);
// Converter belongs to ingress. Type is fixed for one accepted generation.
// Output is {exponent[7:0], sign, explicit significand[7:0]}.
function [16:0] convert_weight;
  input [15:0] raw;
  input bf16_mode;
  reg [7:0] mag, sig, exponent;
  reg sign;
  reg [2:0] msb;
  begin
    sign=raw[15];exponent=raw[14:7];sig={(raw[14:7]!=0),raw[6:0]};
    if(bf16_mode) begin
      if(raw[14:7]==8'hff) begin
        if(raw[6:0]!=0) begin sign=0;exponent=0;sig=0;end
        else begin exponent=8'hfe;sig=8'hff;end
      end
    end else begin
      sign=raw[7];mag=sign ? (~raw[7:0]+8'd1) : raw[7:0];
      msb=0;
      if(mag[7])msb=7;else if(mag[6])msb=6;else if(mag[5])msb=5;
      else if(mag[4])msb=4;else if(mag[3])msb=3;else if(mag[2])msb=2;
      else if(mag[1])msb=1;
      exponent=(mag==0)?8'd0:8'd127+{5'b0,msb};
      sig=mag<<(7-msb);
    end
    convert_weight={exponent,sign,sig};
  end
endfunction


wire [127:0] activation_exp, weight_exp;
wire [15:0] activation_nonzero, weight_nonzero;
wire [127:0] activation_sig, weight_sig;
wire [15:0] operand_sign;
wire [255:0] product;
wire [15:0] product_sign;
wire [95:0] shift;
wire signed [9:0] max_exp, aligned_exp;
wire [303:0] aligned;
genvar lane;
generate for(lane=0;lane<16;lane=lane+1) begin: INGRESS
 wire [15:0] a=LOCAL_WEIGHT_BUFFER ? activation_vec[lane*16+:16]
   : sanitize_bf16(activation_vec[lane*16+:16]);
 wire [15:0] w=LOCAL_WEIGHT_BUFFER ? local_selected_weight[lane*16+:16]
   : sanitize_bf16(direct_weight[lane*16+:16]);
 wire [127:0] i8_vec={int8_vec_hi_i,int8_vec_lo_i};
 wire [7:0] i8=i8_vec[lane*8+:8];
 wire [7:0] i8_mag=i8[7] ? -i8 : i8;
 assign activation_exp[lane*8+:8]=a[14:7];
 assign weight_exp[lane*8+:8]=LOCAL_WEIGHT_BUFFER ? selected_weight_exp[lane*8+:8] : w[14:7];
 assign activation_nonzero[lane]=|a[14:0];
 assign weight_nonzero[lane]=kernel_weight_bf16_mode ? |w[14:0] : |i8;
 assign activation_sig[lane*8+:8]={(a[14:7]!=0),a[6:0]};
 assign weight_sig[lane*8+:8]=kernel_weight_bf16_mode ? {(w[14:7]!=0),w[6:0]} : i8_mag;
 assign operand_sign[lane]=a[15] ^ (kernel_weight_bf16_mode ? w[15] : i8[7]);
end endgenerate
edge_dot16_max x_max(.clk(clk),.activation_exp_i(activation_exp),.weight_exp_i(weight_exp),
 .activation_nonzero_i(activation_nonzero),.weight_nonzero_i(weight_nonzero),
 .weight_bf16_mode_i(kernel_weight_bf16_mode),.max_exp_o(max_exp),.shift_o(shift));
edge_dot16_mul #(.LOCAL_WEIGHT_BUFFER(LOCAL_WEIGHT_BUFFER),.FPGA_DSP_MUL(FPGA_DSP_MUL)) x_mul(
 .clk(clk),.activation_sig_i(activation_sig),.weight_sig_i(weight_sig),.sign_i(operand_sign),
 .activation_i(activation_vec),.fill_valid_i(weight_fill_fire),.fill_weight_i(converted_weight[8:0]),
 .active_bank_i(weight_active_bank_q),.active_weight_o(local_selected_weight),
 .product_o(product),.sign_o(product_sign));
edge_dot16_shifter x_shifter(.clk(clk),.product_i(product),.sign_i(product_sign),
 .shift_i(shift),.max_exp_i(max_exp),.aligned_o(aligned),.max_exp_o(aligned_exp));
edge_dot16_adder_tree x_adder_tree(.clk(clk),.aligned_i(aligned),.max_exp_i(aligned_exp),
 .sum_o(dot16_partial_sum),.partial_exp_o(dot16_partial_exp));
edge_dot16_finalizer x_finalizer(.clk(clk),.dot16_partial_sum(dot16_partial_sum),
 .dot16_partial_exp(dot16_partial_exp),.bf20_o(bf20_o));

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

// One accepted BF16 beat shifts the inactive bank toward lane 0.
// Stream lane 0 first: after sixteen beats every lane owns its final weight.
// Exponents shift in parallel at the central metadata island.
generate if (TRACK_VALID) begin : VALID_TRACKER
  reg [8:0] valid_q;
  always @(posedge clk or negedge rst_b)
    if (!rst_b) valid_q <= 0;
    else valid_q <= {valid_q[7:0],in_valid};
  assign out_valid = valid_q[8];
end else begin : EXTERNAL_VALID
  assign out_valid = 1'b0;
end endgenerate


always @(posedge clk or negedge rst_b) begin
  if (!rst_b) begin
    weight_active_bank_q<=0;
    weight_fill_count_q <= 0;
    weight_pending_q <= 0;
    weight_fill_bf16_q <= 1;
  end else begin
    if (weight_fill_fire) begin
      if (weight_fill_count_q == 0) weight_fill_bf16_q <= weight_bf16_mode_i;
      if (weight_active_bank_q)
        weight_exp_bank0_q <= {converted_weight[16:9],weight_exp_bank0_q[127:8]};
      else
        weight_exp_bank1_q <= {converted_weight[16:9],weight_exp_bank1_q[127:8]};
      weight_fill_count_q <= weight_fill_count_q + 1'b1;
      if (weight_fill_count_q == 15) weight_pending_q <= 1'b1;
    end
    // The parent requests activation only at a safe issue boundary.
    // Bank identity never leaves this dot; partial generations cannot activate.
    if (LOCAL_WEIGHT_BUFFER && weight_activate_i && weight_pending_q) begin
      weight_active_bank_q <= ~weight_active_bank_q;
      weight_pending_q <= 1'b0;
    end

  end
end

`ifndef SYNTHESIS
always @(posedge clk) begin
  if (rst_b && in_valid && LOCAL_WEIGHT_BUFFER
      && $isunknown({selected_weight_lo, selected_weight_hi})) begin
    $display("E4 dot16 consumed unknown local weight row=%0d", ROW_INDEX);
    $finish;
  end
end
`endif

endmodule
