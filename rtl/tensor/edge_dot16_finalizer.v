// N1/N2: resetless scalar normalization and BF20 packing (one RNE).
module edge_dot16_finalizer(
 input clk,
 input signed [22:0] dot16_partial_sum,
 input signed [9:0] dot16_partial_exp,
 output [19:0] bf20_o
);
reg [19:0]  result_bf20_q;

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
wire [19:0] normalized_result_next = pack_normalized_bf20(
  normalize_zero_q, normalize_sign_q, normalize_magnitude_q,
  normalize_shift_q, normalize_exp_field_q);

// Pure arithmetic captures; the engine (or standalone tracker) owns validity.
always @(posedge clk) begin
  normalize_zero_q <= (dot16_partial_sum == 0);
  normalize_sign_q <= dot16_partial_sum[22];
  normalize_magnitude_q <= dot16_partial_magnitude[21:0];
  normalize_shift_q <= encode_pack_shift(dot16_partial_msb, dot16_partial_exp, dot16_partial_exp_field);
  normalize_exp_field_q <= encode_exp_field(dot16_partial_exp_field);
  result_bf20_q <= normalized_result_next;
end

assign bf20_o=result_bf20_q;

// Balanced 16/8/4/2 selection instead of a serial priority loop.
function [4:0] msb_index25;
  input [24:0] value;
  reg [15:0] half;
  reg [7:0] quarter;
  reg [3:0] nibble;
  reg [1:0] pair_bits;
  reg [4:0] index;
  begin
    index[4]=|value[24:16];
    half=index[4]?{7'b0,value[24:16]}:value[15:0];
    index[3]=|half[15:8];quarter=index[3]?half[15:8]:half[7:0];
    index[2]=|quarter[7:4];nibble=index[2]?quarter[7:4]:quarter[3:0];
    index[1]=|nibble[3:2];pair_bits=index[1]?nibble[3:2]:nibble[1:0];
    index[0]=pair_bits[1];
    msb_index25=index;
  end
endfunction

// N1 selects a single signed shift for normal and subnormal packing.
// Positive means right shift with RNE; negative means exact left shift.
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
  reg signed [10:0] sub_right_shift;
  begin
    // exp_field = max_exp + msb - 7. In the subnormal branch,
    // -max_exp-3 >= msb-10 >= -10, so only the large-right cap is needed.
    sub_right_shift=-$signed({max_exp[9],max_exp})-11'sd3;
    encode_pack_shift=(exp_field <= 11'sd0)
      ? ((sub_right_shift > 11'sd26) ? 6'sd26 : sub_right_shift[5:0])
      : ($signed({1'b0,msb}) - 6'sd11);
  end
endfunction

// N2 retains only the destination significand and its carry. Guard/sticky
// are derived from the original magnitude, before discarded bits disappear.
function [19:0] pack_normalized_bf20;
  input zero;
  input sign;
  input [21:0] magnitude;
  input signed [5:0] encoded_shift;
  input [7:0] normalized_exp_field;
  reg [11:0] significand;
  reg guard_bit,sticky_bit;
  reg [12:0] rounded;
  reg [8:0] exp_field;
  integer shift;
  begin
    shift=$signed(encoded_shift);
    guard_bit=0;sticky_bit=0;
    if(shift>0)begin
      significand=magnitude>>shift;
      if(shift<=22)begin
        guard_bit=magnitude[shift-1];
        sticky_bit=|(magnitude&((22'b1<<(shift-1))-1'b1));
      end
    end else significand=magnitude<<(-shift);
    rounded={1'b0,significand}+
      {12'b0,(guard_bit&&(sticky_bit||significand[0]))};
    exp_field={1'b0,normalized_exp_field}+{8'b0,rounded[12]};
    if(zero)pack_normalized_bf20=0;
    else if(normalized_exp_field==0)
      pack_normalized_bf20={sign,7'b0,rounded[11],rounded[10:0]};
    else if(exp_field>=255)pack_normalized_bf20={sign,8'hfe,11'h7ff};
    else pack_normalized_bf20={sign,exp_field[7:0],
      rounded[12]?rounded[11:1]:rounded[10:0]};
  end
endfunction

endmodule
