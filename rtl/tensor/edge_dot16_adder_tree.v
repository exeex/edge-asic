// S5a: four signed 21-bit group sums. S5: signed 23-bit total.
module edge_dot16_adder_tree(input clk,input [303:0] aligned_i,
 input signed [9:0] max_exp_i,output reg signed [22:0] sum_o,
 output signed [9:0] partial_exp_o);
wire signed [18:0] lane[0:15];reg signed [20:0] group_q[0:3];
reg signed [9:0] exp0,exp1;
assign partial_exp_o=exp1-10'sd2;
genvar i;
generate for(i=0;i<16;i=i+1) begin: LANE
 assign lane[i]=aligned_i[i*19+:19];
end
for(i=0;i<4;i=i+1) begin: GROUP
 wire signed [19:0] a={lane[i*4][18],lane[i*4]}+{lane[i*4+1][18],lane[i*4+1]};
 wire signed [19:0] b={lane[i*4+2][18],lane[i*4+2]}+{lane[i*4+3][18],lane[i*4+3]};
 always @(posedge clk) group_q[i]<={a[19],a}+{b[19],b};
end endgenerate
wire signed [21:0] a={group_q[0][20],group_q[0]}+{group_q[1][20],group_q[1]};
wire signed [21:0] b={group_q[2][20],group_q[2]}+{group_q[3][20],group_q[3]};
always @(posedge clk) begin
 exp0<=max_exp_i;exp1<=exp0;sum_o<=$signed({a[21],a})+$signed({b[21],b});
end
endmodule
