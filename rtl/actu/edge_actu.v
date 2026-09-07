`timescale 1ns/1ps

module edge_actu #(
  parameter PIPE_STAGES = 27,
  parameter INPUT_POLICY = 1
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
localparam integer INGRESS_LATENCY = 7;
localparam integer NONLINEAR_LATENCY = 7;
localparam integer TRANSPORT_LATENCY = 6;
localparam integer BACKEND_EGRESS_LATENCY = 1;
localparam integer SEMANTIC_TRANSPORT_STAGES = INGRESS_LATENCY + 4 + 1 + NONLINEAR_LATENCY + 1;
localparam integer POST_STAGES = PIPE_STAGES - INGRESS_LATENCY - NONLINEAR_LATENCY -
                                 TRANSPORT_LATENCY -
                                 BACKEND_EGRESS_LATENCY;

wire   input_fire;
wire        nonlinear_out_valid;
wire [21:0] nonlinear_out_bf22;
wire        front_valid;
wire        front_last;
wire [2:0]  front_mode;
wire [18:0] front_payload_bf19;
wire [21:0] front_primary_bf22;
wire [21:0] front_divisor_bf22;
wire        front_sum_clear;
wire [2:0] front_primary_class, front_divisor_class, front_payload_class;
wire [2:0] aligned_primary_class, aligned_payload_class, aligned_rcp_class;
wire [21:0] primary_operand,payload_operand,rcp_operand;
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

`ifndef SYNTHESIS
initial if (PIPE_STAGES < 27) $fatal(1,"ACTU PIPE_STAGES must be at least 27");
`endif
assign in_ready = cpurst_b;
assign input_fire = in_valid && in_ready;
assign out_valid = finalizer_out_valid;
assign out_mode = finalizer_out_mode;
assign out_value = finalizer_out_value;
assign softmax_sum_valid = finalizer_sum_valid;
assign softmax_sum_done = finalizer_sum_done;
assign softmax_sum_value = INPUT_POLICY && row_nan ? 32'h7fc00000 :
                           INPUT_POLICY && row_inf ? 32'h7f800000 : finalizer_sum_value;

// Semantic results travel beside, and never select operands inside, arithmetic.
// Only valid/control resets. A cancelled packet's action is never observable.
wire [2:0] input_action;
reg [2:0] action_q [0:SEMANTIC_TRANSPORT_STAGES-1];
integer action_stage;
edge_actu_input_action x_input_action(in_mode,in_value[31:16],in_softmax_max,input_action);
always @(posedge forever_cpuclk) begin
  action_q[0]<=input_action;
  for(action_stage=1;action_stage<SEMANTIC_TRANSPORT_STAGES;action_stage=action_stage+1)
    action_q[action_stage]<=action_q[action_stage-1];
end


// The reducer samples the backend output after 20 packet captures. Clear wins
// over a simultaneous element, exactly as in the numerical queue controller.
wire [2:0] sum_action=action_q[SEMANTIC_TRANSPORT_STAGES-1];
reg row_nan,row_inf;
always @(posedge forever_cpuclk or negedge cpurst_b) begin
 if(!cpurst_b)begin row_nan<=0;row_inf<=0;end
 else if(backend_sum_clear)begin row_nan<=0;row_inf<=0;end
 else if(nonlinear_out_valid && aligned_mode==3'd5)begin
  row_nan<=row_nan || sum_action==3'd7;
  row_inf<=row_inf || sum_action==3'd5 ||
           (sum_action==0 && aligned_primary_class==3'd4);
 end
end
wire [21:0] sum_numeric;
// Zero is materialized once at the stateful boundary: unlike a dead numerical
// candidate, an arbitrary zero candidate must not enter a later row sum.
wire [21:0] sum_operand=(INPUT_POLICY && sum_action!=0)?22'b0:aligned_primary_bf22;
edge_actu_softmax_rsum x_softmax_rsum(
 .clk(forever_cpuclk),.cpurst_b(cpurst_b),.clear_i(backend_sum_clear),
 .in_valid_i(nonlinear_out_valid && aligned_mode==3'd5),.in_last_i(backend_last),
 .in_bf22_i(sum_operand),.out_valid_o(finalizer_sum_valid),
 .out_done_o(finalizer_sum_done),.out_sum_bf22_o(sum_numeric));
assign finalizer_sum_value={sum_numeric,10'b0};

wire ingress_valid, ingress_last, ingress_clear, ingress_underflow;
wire [2:0] ingress_mode;
wire [15:0] ingress_value;
wire [21:0] ingress_scalar;
wire signed [9:0] ingress_k;
wire [14:0] ingress_hi;
wire [20:0] ingress_residual_product;
edge_actu_exp_ingress x_exp_ingress (
  .clk(forever_cpuclk),.cpurst_b(cpurst_b),.in_valid(input_fire),
  .in_last(in_last),.in_sum_clear(softmax_sum_clear),.in_mode(in_mode),
  .in_value_bf16(in_value[31:16]),.in_scalar_bits(in_softmax_max),
  .out_valid(ingress_valid),.out_last(ingress_last),.out_sum_clear(ingress_clear),
  .out_mode(ingress_mode),.out_value_bf16(ingress_value),.out_scalar_bf22(ingress_scalar),
  .out_underflow(ingress_underflow),.out_exp2_k(ingress_k),.out_frac_code(),.out_hi(ingress_hi),.out_residual(),
  .out_residual_product(ingress_residual_product)
);

edge_actu_exp_frontend #(.FINITE_INPUTS(INPUT_POLICY)) x_exp_frontend (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(ingress_valid),
  .in_last(ingress_last),
  .in_mode(ingress_mode),
  .in_value_bf16(ingress_value),
  .in_scalar_bf22(ingress_scalar),
  .in_sum_clear(ingress_clear),
  .exp_underflow(ingress_underflow),.exp2_k(ingress_k),.exp_hi(ingress_hi),.exp_residual_product(ingress_residual_product),
  .out_valid(front_valid),
  .out_last(front_last),
  .out_mode(front_mode),
  .out_payload_bf19(front_payload_bf19),
  .out_sum_clear(front_sum_clear),
  .out_primary_bf22(front_primary_bf22),
  .out_divisor_bf22(front_divisor_bf22),
  .out_primary_class(front_primary_class),.out_divisor_class(front_divisor_class),
  .out_payload_class(front_payload_class)
);

edge_actu_rcp_backend #(.FINITE_INPUTS(INPUT_POLICY),.ALIGN_LATENCY(NONLINEAR_LATENCY)) x_rcp_backend (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(front_valid),
  .in_last(front_last),
  .in_mode(front_mode),
  .in_payload_bf19(front_payload_bf19),
  .in_primary_bf22(front_primary_bf22),
  .in_divisor_bf22(front_divisor_bf22),
  .in_primary_class(front_primary_class),.in_divisor_class(front_divisor_class),
  .in_payload_class(front_payload_class),
  .in_sum_clear(front_sum_clear),
  .out_valid(nonlinear_out_valid),
  .out_last(backend_last),
  .out_mode(aligned_mode),
  .out_payload_bf19(aligned_payload_bf19),
  .out_primary_bf22(aligned_primary_bf22),
  .out_rcp_bf22(nonlinear_out_bf22),
  .out_primary_operand(primary_operand),.out_payload_operand(payload_operand),.out_rcp_operand(rcp_operand),
  .out_rcp_class(aligned_rcp_class),
  .out_primary_class(aligned_primary_class),.out_payload_class(aligned_payload_class),
  .out_sum_clear(backend_sum_clear)
);

edge_actu_finalizer_classified #(.INPUT_POLICY(INPUT_POLICY),.FINITE_INPUTS(INPUT_POLICY),.EXTERNAL_RSUM(1),.PREPARED_INPUTS(1),.POST_STAGES(POST_STAGES)) x_finalizer (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(nonlinear_out_valid),
  .in_last(backend_last),
  .in_mode(aligned_mode),
  .in_payload_bf19(aligned_payload_bf19),
  .in_primary_bf22(aligned_primary_bf22),
  .in_rcp_bf22(nonlinear_out_bf22),
  .in_primary_class(aligned_primary_class),
  .in_payload_class(aligned_payload_class),
  .in_rcp_class(aligned_rcp_class),
  .in_primary_operand(primary_operand),.in_payload_operand(payload_operand),.in_rcp_operand(rcp_operand),
  .in_result_action(action_q[SEMANTIC_TRANSPORT_STAGES-1]),
  .in_sum_clear(backend_sum_clear),
  .out_valid(finalizer_out_valid),
  .out_mode(finalizer_out_mode),
  .out_value(finalizer_out_value),
  .softmax_sum_valid(),
  .softmax_sum_done(),
  .softmax_sum_value()
);

endmodule

// Function semantics, deliberately separate from BF add/multiply/rounding.
module edge_actu_input_action(
 input wire [2:0] mode,input wire [15:0] x,input wire [31:0] scalar,
 output reg [2:0] action);
wire [21:0] s=mode==7 ? scalar[31:10] : {scalar[31:16],6'b0};
wire xn=(&x[14:7]) && (|x[6:0]);
wire xi=(&x[14:7]) && !(|x[6:0]);
wire sn=(&s[20:13]) && (|s[12:0]);
wire si=(&s[20:13]) && !(|s[12:0]);
wire scalar_used=mode==5 || mode==7 || (mode==6 && !x[15]);
always @* begin
 action=0;
 if(xn || (scalar_used && sn)) action=7;
 else case(mode)
  0:if(xi)action=x[15]?3'd1:3'd5;
  1:if(xi || x[14:0]==0)action=1;
  2:if(xi)action=x[15]?3'd1:3'd3;
  3:if(xi)action=x[15]?3'd2:3'd5;
  4:if(xi)action=x[15]?3'd4:3'd3;
  5:begin
   if(xi && si && x[15]==s[21])action=7;
   else if(xi)action=x[15]?3'd1:3'd5;
   else if(si)action=s[21]?3'd5:3'd1;
  end
  6:begin
   if(x[15])action=1;
   else if(si && s[21])action=7;
   else if(xi || si || (x[14:0]==0 && s[20:0]==0))action=1;
  end
  7:begin
   if(xi && si)action=7;
   else if(si || s[20:0]==0)action=x[15]?3'd2:3'd1;
   else if(xi)action=(x[15]^s[21])?3'd6:3'd5;
  end
 endcase
end
endmodule
