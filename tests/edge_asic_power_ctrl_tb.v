`timescale 1ns/1ps
module edge_asic_power_ctrl_tb;
  reg clk=0; always #5 clk=~clk;
  reg reset_n=0,cmd_valid=0,cmd_power_on=0,all_accel_idle=1;
  reg asic_power_ready=0;
  wire cmd_ready,cmd_resp_valid,asic_power_enable,asic_ready;
  integer responses=0;

  edge_asic_power_ctrl dut(.*);
  always @(posedge clk) if(cmd_resp_valid) responses<=responses+1;

  task send_power;
    input target;
    begin
      @(negedge clk);cmd_power_on=target;cmd_valid=1;
      while(!cmd_ready)@(negedge clk);
      @(posedge clk);#1;cmd_valid=0;
    end
  endtask

  task wait_response;
    integer timeout;
    begin
      timeout=0;
      while(!cmd_resp_valid&&timeout<20)begin @(negedge clk);timeout=timeout+1;end
      if(!cmd_resp_valid)$fatal(1,"power command response timeout");
      @(posedge clk);#1;
      if(cmd_resp_valid)$fatal(1,"duplicate power response");
    end
  endtask

  initial begin
    repeat(3)@(posedge clk);reset_n=1;
    send_power(1);
    if(!asic_power_enable||cmd_resp_valid||cmd_ready)
      $fatal(1,"power-on did not wait for external ready");
    repeat(3)@(posedge clk);
    asic_power_ready=1;
    wait_response();
    if(!asic_ready||!asic_power_enable)$fatal(1,"ready-on state mismatch");

    send_power(1);wait_response();
    if(!asic_power_enable)$fatal(1,"idempotent on toggled control");

    all_accel_idle=0;send_power(0);
    repeat(3)@(posedge clk);
    if(!asic_power_enable||cmd_resp_valid)
      $fatal(1,"power-off ignored accelerator busy drain");
    all_accel_idle=1;
    @(posedge clk);#1;
    if(asic_power_enable)$fatal(1,"idle drain did not lower power control");
    repeat(2)@(posedge clk);
    if(cmd_resp_valid)$fatal(1,"power-off completed before ready fell");
    asic_power_ready=0;
    wait_response();
    if(asic_ready||asic_power_enable)$fatal(1,"ready-off state mismatch");

    send_power(0);wait_response();
    if(responses!=4)$fatal(1,"power response count mismatch=%0d",responses);
    $display("EDGE_ASIC_POWER_CTRL TEST PASS on_status=1 off_idle_drain=1 off_status=1 idempotent=2");
    $finish;
  end
endmodule
