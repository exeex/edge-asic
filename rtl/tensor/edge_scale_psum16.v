// E4 post-dot scale and partial-sum stage.
// The 8-lane SLD vector is shared by the two physical 8-row groups.
module edge_scale_psum16(
  input wire clk,input wire rst_b,input wire in_valid_i,
  input wire [351:0] dot_bf22_i,input wire [255:0] dot_bf16_i,
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
reg [255:0] dot_d0,dot_d1,psum_d0,psum_d1;
reg [127:0] scale_d0;
reg [351:0] dot_bf22_d0,dot_bf22_d1,rsum_accum_a_q,rsum_accum_b_q;
reg [15:0] scale_product_d1[0:15];
reg signed [9:0] scale_exp_d1[0:15];
reg scale_sign_d1[0:15],scale_zero_d1[0:15];
wire [351:0] add_result_bf22,add_result_a_bf22,add_result_b_bf22;
integer product_lane;
wire [7:0] scale_a_sig[0:15];
wire [7:0] scale_b_sig[0:15];
wire [15:0] scale_product[0:15];

assign out_valid_o=valid_d1&&output_write_d1;

genvar lane;
generate
 for(lane=0;lane<16;lane=lane+1)begin:ADD
  // Follow the dot-kernel multiply shape locally: decode two unsigned 8-bit
  // significands, form one 16-bit product, then capture it at the next stage.
  // This is lane-local RTL, not a shared multiplier instance.
  assign scale_a_sig[lane] = (dot_d0[lane*16+14-:8] == 8'b0)
    ? {1'b0,dot_d0[lane*16+:7]} : {1'b1,dot_d0[lane*16+:7]};
  assign scale_b_sig[lane] = (scale_d0[(lane%8)*16+14-:8] == 8'b0)
    ? {1'b0,scale_d0[(lane%8)*16+:7]}
    : {1'b1,scale_d0[(lane%8)*16+:7]};
  assign scale_product[lane] = scale_a_sig[lane] * scale_b_sig[lane];
  // A and B are fixed physical recurrence cones. The bank command selects
  // after both adds, keeping the one-cycle bank control out of normalization.
  edge_e4_fused_scale_add add_a(
    .scale_product_i(scale_product_d1[lane]),
    .scale_exp_i(scale_exp_d1[lane]),
    .scale_sign_i(scale_sign_d1[lane]),.scale_zero_i(scale_zero_d1[lane]),
    .dot_bf16_i(dot_d1[lane*16+:16]),
    .lhs_bf22_i(lhs_acc_d1?rsum_accum_a_q[lane*22+:22]
                              :dot_bf22_d1[lane*22+:22]),
    .psum_bf16_i(psum_d1[lane*16+:16]),
    .rhs_bf22_i(rhs_clear_d1?22'b0:
      (lhs_acc_d1?rsum_accum_b_q[lane*22+:22]
                  :rsum_accum_a_q[lane*22+:22])),
    .scale_enable_i(scale_enable_d1),.canonical_add_i(rhs_acc_d1),
    .y_o(add_result_a_bf22[lane*22+:22]));
  edge_e4_fused_scale_add add_b(
    .scale_product_i(16'b0),.scale_exp_i(10'sb0),
    .scale_sign_i(1'b0),.scale_zero_i(1'b1),
    .dot_bf16_i(16'b0),.lhs_bf22_i(dot_bf22_d1[lane*22+:22]),
    .psum_bf16_i(16'b0),
    .rhs_bf22_i(rhs_clear_d1?22'b0:rsum_accum_b_q[lane*22+:22]),
    .scale_enable_i(1'b0),.canonical_add_i(1'b1),
    .y_o(add_result_b_bf22[lane*22+:22]));
  assign add_result_bf22[lane*22+:22]=lhs_acc_d1
    ?add_result_a_bf22[lane*22+:22]
    :(rhs_acc_d1&&acc_write_bank_d1?add_result_b_bf22[lane*22+:22]
                                   :add_result_a_bf22[lane*22+:22]);
  assign output_bf16_o[lane*16+:16]=bf16_round(
    add_result_bf22[lane*22+:22]);
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

function [15:0] bf16_round;
 input[21:0]bits;reg[15:0]rounded;
 begin
  if((bits[20:13]==8'hff)&&(bits[12:0]!=0))rounded=16'h7fc0;
  else begin
   rounded=bits[21:6]+(bits[5]&&(|bits[4:0]||bits[6]));
   if(rounded==0&&bits[21])rounded=16'h8000;
  end
  bf16_round=rounded;
 end
endfunction

always @(posedge clk or negedge rst_b)begin
 if(!rst_b)begin valid_d0<=0;valid_d1<=0;scale_enable_d0<=0;
  scale_enable_d1<=0;lhs_acc_d0<=0;lhs_acc_d1<=0;
  lhs_acc_bank_d0<=0;lhs_acc_bank_d1<=0;rhs_acc_d0<=0;rhs_acc_d1<=0;
  rhs_acc_bank_d0<=0;rhs_acc_bank_d1<=0;rhs_clear_d0<=0;rhs_clear_d1<=0;
  acc_write_d0<=0;acc_write_d1<=0;acc_write_bank_d0<=0;acc_write_bank_d1<=0;
  output_write_d0<=0;output_write_d1<=0;
  dot_d0<=0;dot_d1<=0;dot_bf22_d0<=0;dot_bf22_d1<=0;
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
   dot_d0<=dot_bf16_i;
   dot_bf22_d0<=dot_bf22_i;psum_d0<=psum_bf16_i;
   for(product_lane=0;product_lane<8;product_lane=product_lane+1)
    scale_d0[product_lane*16+:16]<=sanitize_bf16(scale_bf16_i[product_lane*16+:16]);
   for(product_lane=0;product_lane<16;product_lane=product_lane+1)
    dot_d0[product_lane*16+:16]<=sanitize_bf16(dot_bf16_i[product_lane*16+:16]);
  end
  if(valid_d0)begin
   scale_enable_d1<=scale_enable_d0;
   lhs_acc_d1<=lhs_acc_d0;lhs_acc_bank_d1<=lhs_acc_bank_d0;
   rhs_acc_d1<=rhs_acc_d0;rhs_acc_bank_d1<=rhs_acc_bank_d0;
   rhs_clear_d1<=rhs_clear_d0;acc_write_d1<=acc_write_d0;
   acc_write_bank_d1<=acc_write_bank_d0;output_write_d1<=output_write_d0;
   dot_d1<=dot_d0;
   dot_bf22_d1<=dot_bf22_d0;psum_d1<=psum_d0;
   for(product_lane=0;product_lane<16;product_lane=product_lane+1)begin
    scale_product_d1[product_lane] <= scale_product[product_lane];
    scale_sign_d1[product_lane] <= dot_d0[product_lane*16+15]
      ^ scale_d0[(product_lane%8)*16+15];
    scale_zero_d1[product_lane] <=
      (dot_d0[product_lane*16+:15] == 0)
      || (scale_d0[(product_lane%8)*16+:15] == 0);
    scale_exp_d1[product_lane] <= $signed({2'b0,
      (dot_d0[product_lane*16+7+:8] == 0)
        ? 8'd1 : dot_d0[product_lane*16+7+:8]})
      + $signed({2'b0,(scale_d0[(product_lane%8)*16+7+:8] == 0)
        ? 8'd1 : scale_d0[(product_lane%8)*16+7+:8]}) - 10'sd253;
   end
  end
  if(valid_d1&&acc_write_d1)begin
   if(acc_write_bank_d1)rsum_accum_b_q<=add_result_bf22;
   else rsum_accum_a_q<=add_result_bf22;
  end
 end
end

endmodule

// One shared align/add/normalize path for unrounded scale products, ordinary
// BF16 dot+PSUM, and BF22 RSUM feedback.  The scale product remains in its
// native 8x8=16-bit significand form until this final addition.
module edge_e4_fused_scale_add(
 input wire[15:0]scale_product_i,input wire signed[9:0]scale_exp_i,
 input wire scale_sign_i,input wire scale_zero_i,
 input wire[15:0]dot_bf16_i,input wire[21:0]lhs_bf22_i,
 input wire[15:0]psum_bf16_i,input wire[21:0]rhs_bf22_i,
 input wire scale_enable_i,input wire canonical_add_i,output wire[21:0]y_o);
reg[15:0]a_raw,b_raw;reg a_sign,b_sign,a_zero,b_zero;
reg signed[9:0]a_exp,b_exp;
reg[7:0]bf16_exp;

function[3:0]msb16;input[15:0]v;integer i;begin msb16=0;
 for(i=0;i<16;i=i+1)if(v[i])msb16=i[3:0];end endfunction
function[4:0]msb19;input[18:0]v;integer i;begin msb19=0;
 for(i=0;i<19;i=i+1)if(v[i])msb19=i[4:0];end endfunction
function[18:0]rshift_sticky19;input[18:0]v;input integer s;reg sticky;begin
 if(s<=0)rshift_sticky19=v;
 else if(s>=19)rshift_sticky19={18'b0,|v};
 else begin sticky=|(v&((19'b1<<s)-19'b1));rshift_sticky19=(v>>s)|sticky;end
end endfunction
function[21:0]pack_bf22;input sign;input signed[10:0]exp;input[18:0]sig;
 reg[13:0]main;reg[14:0]rounded;reg signed[11:0]biased;begin
  if(sig==0)pack_bf22={sign,21'b0};
  else begin main=sig[18:5];rounded={1'b0,main}+
    (sig[4]&&(|sig[3:0]||main[0]));
   biased=$signed(exp)+$signed({11'b0,rounded[14]})+12'sd127;
   if(biased>=255)pack_bf22={sign,8'hfe,13'h1fff};
   else if(biased<=0)pack_bf22={sign,21'b0};
   else pack_bf22={sign,biased[7:0],rounded[14]?rounded[13:1]:rounded[12:0]};
  end
 end endfunction
function[21:0]add_raw;input[15:0]ar,br;input as,bs,az,bz;
 input signed[9:0]ae,be;reg[3:0]am,bm;reg[15:0]an,bn;
 reg signed[10:0]ax,bx,le;reg ls,ss;reg[18:0]large_sig,small_sig,norm_sig;
 reg[19:0]sum;reg[4:0]norm_msb;integer sh;begin
  if(az||ar==0)begin am=0;an=0;ax=-1024;end
  else begin am=msb16(ar);an=ar<<(15-am);ax=ae+$signed({7'b0,am})-11'sd15;end
  if(bz||br==0)begin bm=0;bn=0;bx=-1024;end
  else begin bm=msb16(br);bn=br<<(15-bm);bx=be+$signed({7'b0,bm})-11'sd15;end
  if(an==0)add_raw=pack_bf22(bs,bx,{bn,3'b0});
  else if(bn==0)add_raw=pack_bf22(as,ax,{an,3'b0});
  else begin
   if((bx>ax)||((bx==ax)&&(bn>an)))begin le=bx;ls=bs;ss=as;large_sig={bn,3'b0};sh=bx-ax;small_sig=rshift_sticky19({an,3'b0},sh);end
   else begin le=ax;ls=as;ss=bs;large_sig={an,3'b0};sh=ax-bx;small_sig=rshift_sticky19({bn,3'b0},sh);end
   if(ls==ss)begin sum={1'b0,large_sig}+{1'b0,small_sig};
    if(sum[19])begin norm_sig={sum[19:2],|sum[1:0]};le=le+1;end else norm_sig=sum[18:0];
    add_raw=pack_bf22(ls,le,norm_sig);end
   else if(large_sig==small_sig)add_raw=0;
   else begin norm_sig=large_sig-small_sig;norm_msb=msb19(norm_sig);
    sh=18-norm_msb;if((le-sh)<-126)sh=le+126;
    norm_sig=norm_sig<<sh;le=le-sh;
    add_raw=pack_bf22(ls,le,norm_sig);end
  end
 end endfunction

// RSUM operands are already canonical BF22 values.  Compare their encoded
// exponents directly, select which significand owns the alignment shifter,
// and avoid the generic raw-product leading-bit normalization in add_raw.
function[21:0]add_bf22_canonical;input[21:0]av,bv;
 reg[7:0]aef,bef;reg[13:0]asig,bsig;
 reg signed[10:0]ax,bx,le;reg ls,ss;
 reg[18:0]large_sig,small_sig,norm_sig;reg[19:0]sum;
 reg[4:0]norm_msb;integer sh;begin
  aef=av[20:13];bef=bv[20:13];
  asig=(aef==0)?{1'b0,av[12:0]}:{1'b1,av[12:0]};
  bsig=(bef==0)?{1'b0,bv[12:0]}:{1'b1,bv[12:0]};
  ax=(aef==0)?-11'sd126:$signed({3'b0,aef})-11'sd127;
  bx=(bef==0)?-11'sd126:$signed({3'b0,bef})-11'sd127;
  if(asig==0)add_bf22_canonical=bv;
  else if(bsig==0)add_bf22_canonical=av;
  else begin
   if((bx>ax)||((bx==ax)&&(bsig>asig)))begin
    le=bx;ls=bv[21];ss=av[21];large_sig={bsig,5'b0};
    sh=bx-ax;small_sig=rshift_sticky19({asig,5'b0},sh);
   end else begin
    le=ax;ls=av[21];ss=bv[21];large_sig={asig,5'b0};
    sh=ax-bx;small_sig=rshift_sticky19({bsig,5'b0},sh);
   end
   if(ls==ss)begin
    sum={1'b0,large_sig}+{1'b0,small_sig};
    if(sum[19])begin
     norm_sig={sum[19:2],|sum[1:0]};le=le+1;
    end else norm_sig=sum[18:0];
    add_bf22_canonical=pack_bf22(ls,le,norm_sig);
   end else if(large_sig==small_sig)add_bf22_canonical=0;
   else begin
    norm_sig=large_sig-small_sig;norm_msb=msb19(norm_sig);
    sh=18-norm_msb;if((le-sh)<-126)sh=le+126;
    norm_sig=norm_sig<<sh;le=le-sh;
    add_bf22_canonical=pack_bf22(ls,le,norm_sig);
   end
  end
 end endfunction

always @* begin
 a_raw=0;a_exp=0;a_sign=0;a_zero=1;b_raw=0;b_exp=0;b_sign=0;b_zero=1;
 if(scale_enable_i)begin a_raw=scale_product_i;a_exp=scale_exp_i;a_sign=scale_sign_i;a_zero=scale_zero_i;end
 else begin bf16_exp=dot_bf16_i[14:7];a_raw={(bf16_exp==0)?{1'b0,dot_bf16_i[6:0]}:{1'b1,dot_bf16_i[6:0]},8'b0};
  a_exp=(bf16_exp==0)?-10'sd126:$signed({2'b0,bf16_exp})-10'sd127;a_sign=dot_bf16_i[15];a_zero=(dot_bf16_i[14:0]==0);end
 bf16_exp=psum_bf16_i[14:7];b_raw={(bf16_exp==0)?{1'b0,psum_bf16_i[6:0]}:{1'b1,psum_bf16_i[6:0]},8'b0};
 b_exp=(bf16_exp==0)?-10'sd126:$signed({2'b0,bf16_exp})-10'sd127;b_sign=psum_bf16_i[15];b_zero=(psum_bf16_i[14:0]==0);
end
assign y_o=canonical_add_i?add_bf22_canonical(lhs_bf22_i,rhs_bf22_i):
 add_raw(a_raw,b_raw,a_sign,b_sign,a_zero,b_zero,a_exp,b_exp);
endmodule
