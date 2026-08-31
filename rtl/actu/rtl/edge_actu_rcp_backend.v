`timescale 1ns/1ps

// East-side ACTU backend.  Its ingress register is also the transport endpoint
// for EXP-dependent traffic and the registered bypass endpoint for direct
// RCP/RSQRT/softmax-normalize traffic.
(* keep_hierarchy = "yes" *)
module edge_actu_rcp_backend #(
  parameter ALIGN_LATENCY = 5
) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire        in_valid,
  input  wire [2:0]  in_mode,
  input  wire [18:0] in_payload_bf19,
  input  wire [21:0] in_primary_bf22,
  input  wire [21:0] in_divisor_bf22,
  input  wire        in_sum_clear,
  output wire        out_valid,
  output wire [2:0]  out_mode,
  output wire [18:0] out_payload_bf19,
  output wire [21:0] out_primary_bf22,
  output wire [31:0] out_rcp_bits,
  output wire        out_sum_clear
);

localparam [2:0] EDGE_ACTU_MODE_RSQRT = 3'd6;

reg         ingress_valid_q;
reg [2:0]   ingress_mode_q;
reg [18:0]  ingress_payload_q;
reg [21:0]  ingress_primary_q;
reg [21:0]  ingress_divisor_q;
reg         ingress_sum_clear_q;
reg [2:0]   mode_pipe [0:ALIGN_LATENCY-1];
reg [18:0]  payload_pipe [0:ALIGN_LATENCY-1];
reg [21:0]  primary_pipe [0:ALIGN_LATENCY-1];
reg         sum_clear_pipe [0:ALIGN_LATENCY-1];
integer stage;

wire nonlinear_valid;
wire [31:0] nonlinear_bits;

edge_actu_rcp_rsqrt_pipe x_rcp_rsqrt (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .in_valid(ingress_valid_q),
  .in_rsqrt(ingress_mode_q == EDGE_ACTU_MODE_RSQRT),
  .in_value({ingress_divisor_q, 10'b0}),
  .out_valid(nonlinear_valid),
  .out_value(nonlinear_bits)
);

assign out_valid = nonlinear_valid;
assign out_mode = mode_pipe[ALIGN_LATENCY-1];
assign out_payload_bf19 = payload_pipe[ALIGN_LATENCY-1];
assign out_primary_bf22 = primary_pipe[ALIGN_LATENCY-1];
assign out_rcp_bits = nonlinear_bits;
assign out_sum_clear = sum_clear_pipe[ALIGN_LATENCY-1];

always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    ingress_valid_q <= 1'b0;
    ingress_mode_q <= 3'b0;
    ingress_payload_q <= 19'b0;
    ingress_primary_q <= 22'b0;
    ingress_divisor_q <= 22'b0;
    ingress_sum_clear_q <= 1'b0;
    for (stage = 0; stage < ALIGN_LATENCY; stage = stage + 1) begin
      mode_pipe[stage] <= 3'b0;
      payload_pipe[stage] <= 19'b0;
      primary_pipe[stage] <= 22'b0;
      sum_clear_pipe[stage] <= 1'b0;
    end
  end else begin
    ingress_valid_q <= in_valid;
    ingress_mode_q <= in_mode;
    ingress_payload_q <= in_payload_bf19;
    ingress_primary_q <= in_primary_bf22;
    ingress_divisor_q <= in_divisor_bf22;
    ingress_sum_clear_q <= in_sum_clear;
    mode_pipe[0] <= ingress_mode_q;
    payload_pipe[0] <= ingress_payload_q;
    primary_pipe[0] <= ingress_primary_q;
    sum_clear_pipe[0] <= ingress_sum_clear_q;
    for (stage = 1; stage < ALIGN_LATENCY; stage = stage + 1) begin
      mode_pipe[stage] <= mode_pipe[stage - 1];
      payload_pipe[stage] <= payload_pipe[stage - 1];
      primary_pipe[stage] <= primary_pipe[stage - 1];
      sum_clear_pipe[stage] <= sum_clear_pipe[stage - 1];
    end
  end
end

endmodule
