`timescale 1ns/1ps
module edge_asic_accel_owner_tb;
  reg clk=0; always #5 clk=~clk;
  reg reset_n=0, req_valid=0, cmd_ready=0;
  reg [63:0] req_inst=0, req_capture_value=0;
  reg cmd_decode_illegal=0, cmd_result_valid=0;
  reg [63:0] cmd_result_value=0;
  wire req_ready, cmd_valid, cmd_capture_valid, resp_valid, resp_error;
  wire [63:0] cmd_inst, cmd_capture_value, resp_value;
  integer fires=0;

  edge_asic_accel_owner dut(.*);
  always @(posedge clk) if(cmd_valid&&cmd_ready) fires<=fires+1;

  task issue;
    input [63:0] inst, capture, result;
    input illegal, has_result;
    begin
      req_inst=inst; req_capture_value=capture; req_valid=1;
      cmd_decode_illegal=illegal; cmd_result_valid=has_result;
      cmd_result_value=result;
      repeat(2) begin
        @(posedge clk);
        if(req_ready || cmd_inst!=inst || cmd_capture_value!=capture ||
           !cmd_capture_valid) $fatal(1,"backpressure contract failed");
      end
      @(negedge clk); cmd_ready=1;
      @(posedge clk); #1; req_valid=0; cmd_ready=0;
      if(!resp_valid || resp_error!=illegal ||
         resp_value!=(has_result?result:64'b0))
        $fatal(1,"response contract failed");
      @(posedge clk); #1;
      if(resp_valid) $fatal(1,"duplicate response");
    end
  endtask

  initial begin
    repeat(2) @(posedge clk); reset_n=1;
    issue(64'h1111,64'haaaa,64'h0,0,0);
    issue(64'h2222,64'hbbbb,64'h1234,0,1);
    issue(64'h3333,64'hcccc,64'h0,1,0);
    if(fires!=3) $fatal(1,"command duplication");
    $display("EDGE_ASIC_ACCEL_OWNER TEST PASS");
    $finish;
  end
endmodule
