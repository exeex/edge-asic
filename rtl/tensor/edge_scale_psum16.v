// E4 post-dot scale and partial-sum stage.
// The 8-lane SLD vector is shared by the two physical 8-row groups.
module edge_scale_psum16(
  input wire clk,input wire rst_b,input wire in_valid_i,
  input wire [319:0] dot_bf20_i,
  input wire [255:0] psum_bf16_i,
  input wire scale_enable_i,input wire [127:0] scale_bf16_i,
  input wire lhs_acc_i,input wire lhs_acc_bank_i,
  input wire rhs_acc_i,input wire rhs_acc_bank_i,input wire rhs_clear_i,
  input wire acc_write_i,input wire acc_write_bank_i,input wire output_write_i,
  output wire out_valid_o,output wire [255:0] output_bf16_o
);
reg valid_d0,valid_d1;
reg scale_enable_d0,scale_enable_d1;
reg lhs_acc_d0,lhs_acc_d1,lhs_acc_bank_d0,lhs_acc_bank_d1;
reg rhs_acc_d0,rhs_acc_d1,rhs_acc_bank_d0,rhs_acc_bank_d1;
reg rhs_clear_d0,rhs_clear_d1,acc_write_d0,acc_write_d1;
reg acc_write_bank_d0,acc_write_bank_d1,output_write_d0,output_write_d1;
reg [255:0] psum_d0,psum_d1;
reg [127:0] scale_d0;
reg [319:0] dot_bf20_d0,dot_bf20_d1,rsum_accum_a_q,rsum_accum_b_q;
reg [19:0] scale_product_d1[0:15];
reg signed [9:0] scale_exp_d1[0:15];
reg scale_sign_d1[0:15],scale_zero_d1[0:15];
wire [319:0] add_result_bf20,add_result_a_bf20,add_result_b_bf20;
wire [255:0] result_a_bf16,result_b_bf16;
integer product_lane;
wire [11:0] scale_a_sig[0:15];
wire [7:0] scale_b_sig[0:15];
wire [19:0] scale_product[0:15];

assign out_valid_o=valid_d1&&output_write_d1;

genvar lane;
generate
 for(lane=0;lane<16;lane=lane+1)begin:ADD
  // Follow the dot-kernel multiply shape locally: decode unsigned 12-bit and 8-bit
  // significands, form one 20-bit product, then capture it at the next stage.
  // This is lane-local RTL, not a shared multiplier instance.
  assign scale_a_sig[lane] = (dot_bf20_d0[lane*20+18-:8] == 8'b0)
    ? {1'b0,dot_bf20_d0[lane*20+:11]} : {1'b1,dot_bf20_d0[lane*20+:11]};
  assign scale_b_sig[lane] = (scale_d0[(lane%8)*16+14-:8] == 8'b0)
    ? {1'b0,scale_d0[(lane%8)*16+:7]}
    : {1'b1,scale_d0[(lane%8)*16+:7]};
  assign scale_product[lane] = scale_a_sig[lane] * scale_b_sig[lane];
  // A and B are fixed physical recurrence cones. The bank command selects
  // after both adds, keeping the one-cycle bank control out of normalization.
  edge_fused_scale_add add_a(
    .scale_product_i(scale_product_d1[lane]),
    .scale_exp_i(scale_exp_d1[lane]),
    .scale_sign_i(scale_sign_d1[lane]),.scale_zero_i(scale_zero_d1[lane]),

    .lhs_bf20_i(lhs_acc_d1?rsum_accum_a_q[lane*20+:20]
                              :dot_bf20_d1[lane*20+:20]),
    .psum_bf16_i(psum_d1[lane*16+:16]),
    .rhs_bf20_i(rhs_clear_d1?20'b0:
      (lhs_acc_d1?rsum_accum_b_q[lane*20+:20]
                  :rsum_accum_a_q[lane*20+:20])),
    .scale_enable_i(scale_enable_d1),.canonical_add_i(rhs_acc_d1),
    .bf20_o(add_result_a_bf20[lane*20+:20]),.bf16_o(result_a_bf16[lane*16+:16]));
  edge_fused_scale_add add_b(
    .scale_product_i(20'b0),.scale_exp_i(10'sb0),
    .scale_sign_i(1'b0),.scale_zero_i(1'b1),
    .lhs_bf20_i(dot_bf20_d1[lane*20+:20]),
    .psum_bf16_i(16'b0),
    .rhs_bf20_i(rhs_clear_d1?20'b0:rsum_accum_b_q[lane*20+:20]),
    .scale_enable_i(1'b0),.canonical_add_i(1'b1),
    .bf20_o(add_result_b_bf20[lane*20+:20]),.bf16_o(result_b_bf16[lane*16+:16]));
  assign add_result_bf20[lane*20+:20]=lhs_acc_d1
    ?add_result_a_bf20[lane*20+:20]
    :(rhs_acc_d1&&acc_write_bank_d1?add_result_b_bf20[lane*20+:20]
                                   :add_result_a_bf20[lane*20+:20]);
  assign output_bf16_o[lane*16+:16]=(rhs_acc_d1 && acc_write_bank_d1 && !lhs_acc_d1)
    ? result_b_bf16[lane*16+:16] : result_a_bf16[lane*16+:16];
 end
endgenerate

function [15:0] sanitize_bf16;
 input [15:0] value;
 begin
  if((value[14:7]==8'hff)&&(value[6:0]!=0))sanitize_bf16=16'h0000;
  else if(value[14:0]==15'h7f80)sanitize_bf16=value[15]?16'hff7f:16'h7f7f;
  else sanitize_bf16=value;
 end
endfunction

always @(posedge clk or negedge rst_b)begin
 if(!rst_b)begin valid_d0<=0;valid_d1<=0;scale_enable_d0<=0;
  scale_enable_d1<=0;lhs_acc_d0<=0;lhs_acc_d1<=0;
  lhs_acc_bank_d0<=0;lhs_acc_bank_d1<=0;rhs_acc_d0<=0;rhs_acc_d1<=0;
  rhs_acc_bank_d0<=0;rhs_acc_bank_d1<=0;rhs_clear_d0<=0;rhs_clear_d1<=0;
  acc_write_d0<=0;acc_write_d1<=0;acc_write_bank_d0<=0;acc_write_bank_d1<=0;
  output_write_d0<=0;output_write_d1<=0;
  dot_bf20_d0<=0;dot_bf20_d1<=0;
  psum_d0<=0;psum_d1<=0;scale_d0<=0;
  rsum_accum_a_q<=0;rsum_accum_b_q<=0;
  for(product_lane=0;product_lane<16;product_lane=product_lane+1)begin
   scale_product_d1[product_lane]<=0;scale_exp_d1[product_lane]<=0;
   scale_sign_d1[product_lane]<=0;scale_zero_d1[product_lane]<=1;
  end
 end
 else begin
  valid_d0<=in_valid_i;valid_d1<=valid_d0;
  if(in_valid_i)begin
   scale_enable_d0<=scale_enable_i;
   lhs_acc_d0<=lhs_acc_i;lhs_acc_bank_d0<=lhs_acc_bank_i;
   rhs_acc_d0<=rhs_acc_i;rhs_acc_bank_d0<=rhs_acc_bank_i;
   rhs_clear_d0<=rhs_clear_i;acc_write_d0<=acc_write_i;
   acc_write_bank_d0<=acc_write_bank_i;output_write_d0<=output_write_i;
   dot_bf20_d0<=dot_bf20_i;psum_d0<=psum_bf16_i;
   for(product_lane=0;product_lane<8;product_lane=product_lane+1)
    scale_d0[product_lane*16+:16]<=sanitize_bf16(scale_bf16_i[product_lane*16+:16]);
  end
  if(valid_d0)begin
   scale_enable_d1<=scale_enable_d0;
   lhs_acc_d1<=lhs_acc_d0;lhs_acc_bank_d1<=lhs_acc_bank_d0;
   rhs_acc_d1<=rhs_acc_d0;rhs_acc_bank_d1<=rhs_acc_bank_d0;
   rhs_clear_d1<=rhs_clear_d0;acc_write_d1<=acc_write_d0;
   acc_write_bank_d1<=acc_write_bank_d0;output_write_d1<=output_write_d0;
   dot_bf20_d1<=dot_bf20_d0;psum_d1<=psum_d0;
   for(product_lane=0;product_lane<16;product_lane=product_lane+1)begin
    scale_product_d1[product_lane] <= scale_product[product_lane];
    scale_sign_d1[product_lane] <= dot_bf20_d0[product_lane*20+19]
      ^ scale_d0[(product_lane%8)*16+15];
    scale_zero_d1[product_lane] <=
      (dot_bf20_d0[product_lane*20+:19] == 0)
      || (scale_d0[(product_lane%8)*16+:15] == 0);
    scale_exp_d1[product_lane] <= $signed({2'b0,
      (dot_bf20_d0[product_lane*20+11+:8] == 0)
        ? 8'd1 : dot_bf20_d0[product_lane*20+11+:8]})
      + $signed({2'b0,(scale_d0[(product_lane%8)*16+7+:8] == 0)
        ? 8'd1 : scale_d0[(product_lane%8)*16+7+:8]}) - 10'sd253;
   end
  end
  if(valid_d1&&acc_write_d1)begin
   if(acc_write_bank_d1)rsum_accum_b_q<=add_result_bf20;
   else rsum_accum_a_q<=add_result_bf20;
  end
 end
end

endmodule

// Common unrounded arithmetic result. Each consumer rounds directly to its
// destination: BF20 feedback or BF16 output. No BF20-to-BF16 double rounding.
module edge_fused_scale_add(
 input wire [19:0] scale_product_i,input wire signed [9:0] scale_exp_i,
 input wire scale_sign_i,input wire scale_zero_i,
 input wire [19:0] lhs_bf20_i,rhs_bf20_i,input wire [15:0] psum_bf16_i,
 input wire scale_enable_i,canonical_add_i,
 output wire [19:0] bf20_o,output wire [15:0] bf16_o
);
reg [19:0] ar,br;
reg signed [10:0] ax,bx,le;
reg as,bs,ls,ss;
reg [22:0] large_sig,small_sig,norm_sig;
reg [23:0] sum;
integer am,sh;
function integer msb20;input [19:0] v;integer i;begin
 msb20=0;for(i=0;i<20;i=i+1)if(v[i])msb20=i;
end endfunction
function integer msb23;input [22:0] v;integer i;begin
 msb23=0;for(i=0;i<23;i=i+1)if(v[i])msb23=i;
end endfunction
function [22:0] sticky_shift;input [22:0] v;input integer amount;begin
 if(amount<=0)sticky_shift=v;
 else if(amount>=23)sticky_shift={22'b0,|v};
 else sticky_shift=(v>>amount) | (|(v & ((23'b1<<amount)-1'b1)));
end endfunction
// The significand has its leading bit at 22, plus all product precision and
// alignment sticky. Subnormal shift precedes RNE, so underflow rounds once.
function [19:0] pack_result;
 input sign;input signed [10:0] exp;input [22:0] sig;input integer frac;
 reg [22:0] shifted,q;reg increment;integer biased,cut;reg [19:0] payload;
 begin
  shifted=sticky_shift(sig,(-126-exp)>0?(-126-exp):0);
  cut=22-frac;
  q=shifted>>cut;
  increment=shifted[cut-1] && ((|(shifted&((23'b1<<(cut-1))-1'b1)))||q[0]);
  q=q+increment;biased=(exp < -126)?1:exp+127;
  if(q>=(23'b1<<(frac+1)))begin q=q>>1;biased=biased+1;end
  if(biased>=255)payload=(frac==11)?20'h7f7ff:20'h07f80;
  else if(q<(23'b1<<frac))payload=q;
  else payload=(biased<<frac)|(q&((23'b1<<frac)-1'b1));
  pack_result=payload | (20'(sign)<<(frac+8));
 end
endfunction
always @* begin
 ar={(lhs_bf20_i[18:11]!=0),lhs_bf20_i[10:0],8'b0};
 br={(rhs_bf20_i[18:11]!=0),rhs_bf20_i[10:0],8'b0};
 ax=(lhs_bf20_i[18:11]==0)?-11'sd126:$signed({3'b0,lhs_bf20_i[18:11]})-11'sd127;
 bx=(rhs_bf20_i[18:11]==0)?-11'sd126:$signed({3'b0,rhs_bf20_i[18:11]})-11'sd127;
 as=lhs_bf20_i[19];bs=rhs_bf20_i[19];
 am=0;sum=0;sh=0;
 if(!canonical_add_i)begin
  br={(psum_bf16_i[14:7]!=0),psum_bf16_i[6:0],12'b0};
  bx=(psum_bf16_i[14:7]==0)?-11'sd126:$signed({3'b0,psum_bf16_i[14:7]})-11'sd127;
  bs=psum_bf16_i[15];
  if(scale_enable_i)begin
   ar=scale_zero_i?20'b0:scale_product_i;ax=scale_exp_i;as=scale_sign_i;
   am=msb20(ar);ar=ar<<(19-am);ax=ax+am-19;
  end
 end
 if(ar==0)ax=-11'sd1024;
 if(br==0)bx=-11'sd1024;
 if((bx>ax)||((bx==ax)&&(br>ar)))begin
  le=bx;ls=bs;ss=as;large_sig={br,3'b0};small_sig=sticky_shift({ar,3'b0},bx-ax);
 end else begin
  le=ax;ls=as;ss=bs;large_sig={ar,3'b0};small_sig=sticky_shift({br,3'b0},ax-bx);
 end
 if(ls==ss)begin
  sum={1'b0,large_sig}+{1'b0,small_sig};
  if(sum[23])begin norm_sig={sum[23:2],|sum[1:0]};le=le+1;end
  else norm_sig=sum[22:0];
 end else begin
  norm_sig=large_sig-small_sig;
  if(norm_sig==0)ls=0;
 end
 if(norm_sig!=0)begin sh=22-msb23(norm_sig);norm_sig=norm_sig<<sh;le=le-sh;end
end
assign bf20_o=pack_result(ls,le,norm_sig,11);
wire [19:0] packed_bf16=pack_result(ls,le,norm_sig,7);
assign bf16_o=packed_bf16[15:0];
endmodule
