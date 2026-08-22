`timescale 1ns/1ps

// Owns the blocking edge.asic.power command and the external ASIC-domain
// power-control/status handshake shared by E3 and E4 product compositions.
module edge_asic_power_ctrl (
  input  wire clk,
  input  wire reset_n,
  input  wire cmd_valid,
  output wire cmd_ready,
  input  wire cmd_power_on,
  input  wire all_accel_idle,
  output wire cmd_resp_valid,
  output wire asic_power_enable,
  input  wire asic_power_ready,
  output wire asic_ready
);
  reg ready_meta_q,ready_sync_q;
  reg power_enable_q,pending_q,target_on_q,resp_q;

  assign cmd_ready=!pending_q&&!resp_q;
  assign cmd_resp_valid=resp_q;
  assign asic_power_enable=power_enable_q;
  assign asic_ready=ready_sync_q;

  always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
      ready_meta_q<=1'b0;
      ready_sync_q<=1'b0;
      power_enable_q<=1'b0;
      pending_q<=1'b0;
      target_on_q<=1'b0;
      resp_q<=1'b0;
    end else begin
      ready_meta_q<=asic_power_ready;
      ready_sync_q<=ready_meta_q;
      resp_q<=1'b0;

      if(cmd_valid&&cmd_ready) begin
        target_on_q<=cmd_power_on;
        if(cmd_power_on) begin
          power_enable_q<=1'b1;
          if(ready_sync_q) resp_q<=1'b1;
          else pending_q<=1'b1;
        end else if(!power_enable_q&&!ready_sync_q) begin
          resp_q<=1'b1;
        end else begin
          pending_q<=1'b1;
        end
      end

      if(pending_q) begin
        if(target_on_q) begin
          if(ready_sync_q) begin
            pending_q<=1'b0;
            resp_q<=1'b1;
          end
        end else begin
          if(power_enable_q&&all_accel_idle)
            power_enable_q<=1'b0;
          if(!power_enable_q&&!ready_sync_q) begin
            pending_q<=1'b0;
            resp_q<=1'b1;
          end
        end
      end
    end
  end
endmodule
