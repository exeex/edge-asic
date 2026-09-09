// N1/N2: resetless scalar normalization and BF22 packing, followed by BF16 RNE.
module edge_dot16_finalizer(
 input clk,
 input signed [22:0] dot16_partial_sum,
 input signed [9:0] dot16_partial_exp,
 output [21:0] bf22_o,
 output [15:0] bf16_o
);
reg [21:0]  result_bf22_q;

reg         normalize_zero_q;
reg         normalize_sign_q;
reg [21:0]  normalize_magnitude_q;
reg signed [5:0] normalize_shift_q;
reg [7:0] normalize_exp_field_q;
wire [22:0] partial_abs = dot16_partial_sum[22] ? -dot16_partial_sum : dot16_partial_sum;
wire [24:0] dot16_partial_magnitude = {2'b0,partial_abs};
wire [4:0] dot16_partial_msb = msb_index25(dot16_partial_magnitude);
wire signed [10:0] dot16_partial_exp_field =
    $signed({dot16_partial_exp[9],dot16_partial_exp})
  + $signed({6'b0,dot16_partial_msb}) - 11'sd7;
wire [21:0] normalized_result_next = pack_normalized_bf22(
  normalize_zero_q, normalize_sign_q, {3'b0,normalize_magnitude_q},
  normalize_shift_q, normalize_exp_field_q);

// Pure arithmetic captures; the engine (or standalone tracker) owns validity.
always @(posedge clk) begin
  normalize_zero_q <= (dot16_partial_sum == 0);
  normalize_sign_q <= dot16_partial_sum[22];
  normalize_magnitude_q <= dot16_partial_magnitude[21:0];
  normalize_shift_q <= encode_pack_shift(dot16_partial_msb, dot16_partial_exp, dot16_partial_exp_field);
  normalize_exp_field_q <= encode_exp_field(dot16_partial_exp_field);
  result_bf22_q <= normalized_result_next;
end

assign bf22_o=result_bf22_q;
assign bf16_o=bf16_round_bits(result_bf22_q);
function [4:0] msb_index25;
  input [24:0] value;
  integer idx;
  begin
    msb_index25=0;
    for(idx=0;idx<25;idx=idx+1)
      if(value[idx])msb_index25=idx[4:0];
  end
endfunction

function [24:0] rshift_rne25;
  input [24:0] value;
  input integer amount;
  reg [24:0] quotient;
  reg guard_bit,sticky_bit;
  begin
    if(amount<=0)rshift_rne25=value;
    else if(amount>=26)rshift_rne25=25'b0;
    else begin
      quotient=value>>amount;
      guard_bit=value[amount-1];
      sticky_bit=(amount<=1)?1'b0:|(value&((25'b1<<(amount-1))-1'b1));
      rshift_rne25=quotient+(guard_bit&&(sticky_bit||quotient[0]));
    end
  end
endfunction

// N1 selects a single signed shift for normal and subnormal packing.
// Positive means right shift with RNE; negative means exact left shift.
function signed [5:0] encode_sub_shift;
  input signed [9:0] max_exp;
  reg signed [10:0] full_shift;
  begin
    full_shift=$signed({max_exp[9],max_exp})+11'sd5;
    encode_sub_shift=(full_shift < -11'sd26) ? -6'sd26
                   : (full_shift > 11'sd25) ? 6'sd25 : full_shift[5:0];
  end
endfunction

function [7:0] encode_exp_field;
  input signed [10:0] exp_field;
  begin
    encode_exp_field=(exp_field <= 11'sd0) ? 8'd0
                   : (exp_field >= 11'sd255) ? 8'd255 : exp_field[7:0];
  end
endfunction

function signed [5:0] encode_pack_shift;
  input [4:0] msb;
  input signed [9:0] max_exp;
  input signed [10:0] exp_field;
  begin
    encode_pack_shift=(exp_field <= 11'sd0)
      ? -encode_sub_shift(max_exp) : ($signed({1'b0,msb}) - 6'sd13);
  end
endfunction

function [21:0] pack_normalized_bf22;
  input zero;
  input sign;
  input [24:0] magnitude;
  input signed [5:0] encoded_shift;
  input [7:0] normalized_exp_field;
  reg [24:0] shifted;
  reg [14:0] rounded;
  integer exp_field,shift;
  begin
    exp_field = normalized_exp_field;
    shift=$signed(encoded_shift);
    if(shift>0)shifted=rshift_rne25(magnitude,shift);
    else shifted=magnitude<<(-shift);
    if(zero)pack_normalized_bf22=0;
    else begin
      if(exp_field>=255)pack_normalized_bf22={sign,8'hfe,13'h1fff};
      else if(exp_field>0)begin
        rounded=shifted[14:0];
        if(rounded[14])begin
          rounded={1'b0,rounded[14:1]};
          exp_field=exp_field+1;
        end
        if(exp_field>=255)pack_normalized_bf22={sign,8'hfe,13'h1fff};
        else pack_normalized_bf22={sign,exp_field[7:0],rounded[12:0]};
      end else begin
        if(shifted>=25'd8192)pack_normalized_bf22={sign,8'h01,13'b0};
        else pack_normalized_bf22={sign,8'h00,shifted[12:0]};
      end
    end
  end
endfunction

function [15:0] bf16_round_bits;
  input [21:0] bits;
  reg [15:0] rounded;
  begin
    if ((bits[20:13] == 8'hff) && (bits[12:0] != 13'b0))
      rounded = 16'h7fc0;
    else begin
      rounded = bits[21:6]
              + {15'b0, (bits[5] && (|bits[4:0] || bits[6]))};
      if ((rounded == 16'h0000) && bits[21])
        rounded = 16'h8000;
    end
    bf16_round_bits = rounded;
  end
endfunction

endmodule
