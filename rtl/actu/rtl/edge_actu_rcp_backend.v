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
  input  wire        in_last,
  input  wire [2:0]  in_mode,
  input  wire [18:0] in_payload_bf19,
  input  wire [21:0] in_primary_bf22,
  input  wire [21:0] in_divisor_bf22,
  input  wire        in_sum_clear,
  output wire        out_valid,
  output wire        out_last,
  output wire [2:0]  out_mode,
  output wire [18:0] out_payload_bf19,
  output wire [21:0] out_primary_bf22,
  output wire [21:0] out_rcp_bf22,
  output wire        out_sum_clear
);

localparam [2:0] EDGE_ACTU_MODE_RSQRT = 3'd6;

reg         ingress_valid_q;
reg         ingress_last_q;
reg [2:0]   ingress_mode_q;
reg [18:0]  ingress_payload_q;
reg [21:0]  ingress_primary_q;
reg [21:0]  ingress_divisor_q;
reg         ingress_sum_clear_q;
reg [2:0]   mode_pipe [0:ALIGN_LATENCY-1];
reg [18:0]  payload_pipe [0:ALIGN_LATENCY-1];
reg [21:0]  primary_pipe [0:ALIGN_LATENCY-1];
reg         sum_clear_pipe [0:ALIGN_LATENCY-1];
reg         last_pipe [0:ALIGN_LATENCY-1];
reg         egress_valid_q;
reg         egress_last_q;
reg [2:0]   egress_mode_q;
reg [18:0]  egress_payload_q;
reg [21:0]  egress_primary_q;
reg [21:0]  egress_rcp_q;
reg         egress_sum_clear_q;
integer stage;

wire nonlinear_valid;
wire [21:0] nonlinear_bf22;

edge_actu_rcp_rsqrt_pipe x_rcp_rsqrt (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .in_valid(ingress_valid_q),
  .in_rsqrt(ingress_mode_q == EDGE_ACTU_MODE_RSQRT),
  .in_value_bf22(ingress_divisor_q),
  .out_valid(nonlinear_valid),
  .out_value_bf22(nonlinear_bf22)
);

assign out_valid = egress_valid_q;
assign out_last = egress_last_q;
assign out_mode = egress_mode_q;
assign out_payload_bf19 = egress_payload_q;
assign out_primary_bf22 = egress_primary_q;
assign out_rcp_bf22 = egress_rcp_q;
assign out_sum_clear = egress_sum_clear_q;

// Reset cancels valid and standalone control pulses, not payload/mode state.
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    ingress_valid_q<=0; ingress_last_q<=0; ingress_sum_clear_q<=0;
    egress_valid_q<=0; egress_last_q<=0; egress_sum_clear_q<=0;
    for(stage=0;stage<ALIGN_LATENCY;stage=stage+1)begin
      last_pipe[stage]<=0;sum_clear_pipe[stage]<=0;
    end
  end else begin
    ingress_valid_q<=in_valid;ingress_last_q<=in_last;ingress_sum_clear_q<=in_sum_clear;
    egress_valid_q<=nonlinear_valid;
    egress_last_q<=last_pipe[ALIGN_LATENCY-1];
    egress_sum_clear_q<=sum_clear_pipe[ALIGN_LATENCY-1];
    last_pipe[0]<=ingress_last_q;sum_clear_pipe[0]<=ingress_sum_clear_q;
    for(stage=1;stage<ALIGN_LATENCY;stage=stage+1)begin
      last_pipe[stage]<=last_pipe[stage-1];sum_clear_pipe[stage]<=sum_clear_pipe[stage-1];
    end
  end
end

integer data_stage;
always @(posedge clk) begin
    ingress_mode_q <= in_mode;
    ingress_payload_q <= in_payload_bf19;
    ingress_primary_q <= in_primary_bf22;
    ingress_divisor_q <= in_divisor_bf22;
    egress_mode_q <= mode_pipe[ALIGN_LATENCY-1];
    egress_payload_q <= payload_pipe[ALIGN_LATENCY-1];
    egress_primary_q <= primary_pipe[ALIGN_LATENCY-1];
    egress_rcp_q <= nonlinear_bf22;
    mode_pipe[0] <= ingress_mode_q;
    payload_pipe[0] <= ingress_payload_q;
    primary_pipe[0] <= ingress_primary_q;
    for (data_stage = 1; data_stage < ALIGN_LATENCY; data_stage = data_stage + 1) begin
      mode_pipe[data_stage] <= mode_pipe[data_stage - 1];
      payload_pipe[data_stage] <= payload_pipe[data_stage - 1];
      primary_pipe[data_stage] <= primary_pipe[data_stage - 1];
    end
end

endmodule
