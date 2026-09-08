`timescale 1ns/1ps

// East-side ACTU backend.  Its ingress register is also the transport endpoint
// for EXP-dependent traffic and the registered bypass endpoint for direct
// RCP/RSQRT/softmax-normalize traffic.
(* keep_hierarchy = "yes" *)
module edge_actu_rcp_backend #(
  parameter FINITE_INPUTS = 0,
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
  input  wire [2:0]  in_primary_class, in_divisor_class, in_payload_class,
  input  wire        in_sum_clear,
  output wire        out_valid,
  output wire        out_last,
  output wire [2:0]  out_mode,
  output wire [18:0] out_payload_bf19,
  output wire [21:0] out_primary_bf22,
  output wire [21:0] out_rcp_bf22,
  output wire [2:0]  out_primary_class, out_payload_class, out_rcp_class,
  output reg [21:0] out_primary_operand,out_payload_operand,out_rcp_operand,
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
reg [2:0] ingress_primary_class_q, ingress_divisor_class_q, ingress_payload_class_q;
reg [2:0] primary_class_pipe [0:ALIGN_LATENCY-1];
reg [2:0] payload_class_pipe [0:ALIGN_LATENCY-1];
reg [2:0] egress_primary_class_q, egress_payload_class_q;
assign out_primary_class=egress_primary_class_q;
assign out_payload_class=egress_payload_class_q;
function [21:0] prepare_operand;
 input [21:0] b;
 reg ez;
 begin ez=(b[20:13]==0);prepare_operand={ez?8'd1:b[20:13],!ez,b[12:0]};end
endfunction
always @(posedge clk)begin
 out_primary_operand<=prepare_operand(primary_pipe[ALIGN_LATENCY-1]);
 out_payload_operand<=prepare_operand({payload_pipe[ALIGN_LATENCY-1],3'b0});
 out_rcp_operand<=prepare_operand(nonlinear_bf22);
end
integer stage;

wire nonlinear_valid;
wire [21:0] nonlinear_bf22;
wire [2:0] nonlinear_class;
reg [2:0] egress_rcp_class_q;
assign out_rcp_class=egress_rcp_class_q;

edge_actu_rcp_rsqrt_classified_pipe #(.FINITE_INPUTS(FINITE_INPUTS)) x_rcp_rsqrt (
  .clk(clk),
  .cpurst_b(cpurst_b),
  .in_valid(ingress_valid_q),
  .in_rsqrt(ingress_mode_q == EDGE_ACTU_MODE_RSQRT),
  .in_value_bf22(ingress_divisor_q),
  .in_value_class(ingress_divisor_class_q),
  .out_value_class(nonlinear_class),
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

integer class_stage;
always @(posedge clk) begin
  egress_rcp_class_q<=nonlinear_class;
  ingress_primary_class_q<=in_primary_class;
  ingress_divisor_class_q<=in_divisor_class;
  ingress_payload_class_q<=in_payload_class;
  primary_class_pipe[0]<=ingress_primary_class_q;
  payload_class_pipe[0]<=ingress_payload_class_q;
  for(class_stage=1;class_stage<ALIGN_LATENCY;class_stage=class_stage+1)begin
    primary_class_pipe[class_stage]<=primary_class_pipe[class_stage-1];
    payload_class_pipe[class_stage]<=payload_class_pipe[class_stage-1];
  end
  egress_primary_class_q<=primary_class_pipe[ALIGN_LATENCY-1];
  egress_payload_class_q<=payload_class_pipe[ALIGN_LATENCY-1];
end

`ifndef SYNTHESIS
// Independent observer for materialized classes. ZERO/INF EXP candidates may carry
// arbitrary magnitude; end-to-end equivalence tests verify their semantic class.
function [2:0] expected_class;
  input [21:0] bits;
  begin
    expected_class=3'd0;
    case(bits[20:13])
      8'h00:expected_class=(|bits[12:0]) ? 3'd2 : 3'd1;
      8'hff:expected_class=(|bits[12:0]) ? 3'd5 : 3'd4;
      default:expected_class=3'd0;
    endcase
  end
endfunction
function [2:0] expected_input_class;
 input [21:0] bits;
 begin expected_input_class=FINITE_INPUTS ? (bits[20:0]==0 ? 3'd1 : 3'd0) : expected_class(bits);end
endfunction
wire class_invalid=(ingress_divisor_class_q==3'd1)||
                   (ingress_divisor_class_q==3'd4)||
                   (ingress_divisor_class_q==3'd5)||
                   ((ingress_mode_q==EDGE_ACTU_MODE_RSQRT)&&ingress_divisor_q[21]);
always @(posedge clk) if(cpurst_b)begin
  if(in_valid && ({in_primary_class,in_divisor_class,in_payload_class} !==
    {((in_primary_class==3'd1 || in_primary_class==3'd3 || in_primary_class==3'd4) ? in_primary_class : expected_class(in_primary_bf22)),((FINITE_INPUTS || in_divisor_class==3'd1 || in_divisor_class==3'd3) ? in_divisor_class : expected_input_class(in_divisor_bf22)),expected_input_class({in_payload_bf19,3'b0})}))
    $fatal(1,"ACTU frontend class/data mismatch");
  if(ingress_valid_q)begin
    if({ingress_primary_class_q,ingress_divisor_class_q,ingress_payload_class_q} !==
       {((ingress_primary_class_q==3'd1 || ingress_primary_class_q==3'd3 || ingress_primary_class_q==3'd4) ? ingress_primary_class_q : expected_class(ingress_primary_q)),((FINITE_INPUTS || ingress_divisor_class_q==3'd1 || ingress_divisor_class_q==3'd3) ? ingress_divisor_class_q : expected_input_class(ingress_divisor_q)),expected_input_class({ingress_payload_q,3'b0})})
      $fatal(1,"ACTU backend ingress class/data mismatch");
    if(!FINITE_INPUTS && ingress_divisor_class_q!=3'd1 && class_invalid !== ((ingress_divisor_q[20:0]==0) ||
       (ingress_divisor_q[20:13]==8'hff) ||
       ((ingress_mode_q==EDGE_ACTU_MODE_RSQRT)&&ingress_divisor_q[21])))
      $fatal(1,"ACTU class-derived nonlinear case differs from existing decode");
  end
  if(out_valid && ((out_rcp_class==3'd0 && expected_class(out_rcp_bf22)!=3'd0) ||
     (out_rcp_class!=3'd0 && out_rcp_class!=3'd1)))
    $fatal(1,"ACTU reciprocal result class/data mismatch");
  if(out_valid && ({out_primary_class,out_payload_class} !==
     {((out_primary_class==3'd1 || out_primary_class==3'd3 || out_primary_class==3'd4) ? out_primary_class : expected_class(out_primary_bf22)),expected_input_class({out_payload_bf19,3'b0})}))
    $fatal(1,"ACTU backend egress class/data mismatch");
end
`endif

endmodule
