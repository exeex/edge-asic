`timescale 1ns/1ps

module edge_actu #(
  parameter PIPE_STAGES = 27
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
assign softmax_sum_value = finalizer_sum_value;

wire ingress_valid, ingress_last, ingress_clear, ingress_underflow;
wire [2:0] ingress_mode;
wire [15:0] ingress_value;
wire [21:0] ingress_scalar;
wire signed [9:0] ingress_k;
wire [11:0] ingress_frac;
edge_actu_exp_ingress x_exp_ingress (
  .clk(forever_cpuclk),.cpurst_b(cpurst_b),.in_valid(input_fire),
  .in_last(in_last),.in_sum_clear(softmax_sum_clear),.in_mode(in_mode),
  .in_value_bf16(in_value[31:16]),.in_scalar_bits(in_softmax_max),
  .out_valid(ingress_valid),.out_last(ingress_last),.out_sum_clear(ingress_clear),
  .out_mode(ingress_mode),.out_value_bf16(ingress_value),.out_scalar_bf22(ingress_scalar),
  .out_underflow(ingress_underflow),.out_exp2_k(ingress_k),.out_frac_code(ingress_frac)
);

edge_actu_exp_frontend x_exp_frontend (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(ingress_valid),
  .in_last(ingress_last),
  .in_mode(ingress_mode),
  .in_value_bf16(ingress_value),
  .in_scalar_bf22(ingress_scalar),
  .in_sum_clear(ingress_clear),
  .exp_underflow(ingress_underflow),.exp2_k(ingress_k),.frac_code(ingress_frac),
  .out_valid(front_valid),
  .out_last(front_last),
  .out_mode(front_mode),
  .out_payload_bf19(front_payload_bf19),
  .out_sum_clear(front_sum_clear),
  .out_primary_bf22(front_primary_bf22),
  .out_divisor_bf22(front_divisor_bf22)
);

edge_actu_rcp_backend #(.ALIGN_LATENCY(NONLINEAR_LATENCY)) x_rcp_backend (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(front_valid),
  .in_last(front_last),
  .in_mode(front_mode),
  .in_payload_bf19(front_payload_bf19),
  .in_primary_bf22(front_primary_bf22),
  .in_divisor_bf22(front_divisor_bf22),
  .in_sum_clear(front_sum_clear),
  .out_valid(nonlinear_out_valid),
  .out_last(backend_last),
  .out_mode(aligned_mode),
  .out_payload_bf19(aligned_payload_bf19),
  .out_primary_bf22(aligned_primary_bf22),
  .out_rcp_bf22(nonlinear_out_bf22),
  .out_sum_clear(backend_sum_clear)
);

edge_actu_finalizer #(.POST_STAGES(POST_STAGES)) x_finalizer (
  .clk(forever_cpuclk),
  .cpurst_b(cpurst_b),
  .in_valid(nonlinear_out_valid),
  .in_last(backend_last),
  .in_mode(aligned_mode),
  .in_payload_bf19(aligned_payload_bf19),
  .in_primary_bf22(aligned_primary_bf22),
  .in_rcp_bf22(nonlinear_out_bf22),
  .in_sum_clear(backend_sum_clear),
  .out_valid(finalizer_out_valid),
  .out_mode(finalizer_out_mode),
  .out_value(finalizer_out_value),
  .softmax_sum_valid(finalizer_sum_valid),
  .softmax_sum_done(finalizer_sum_done),
  .softmax_sum_value(finalizer_sum_value)
);

endmodule
