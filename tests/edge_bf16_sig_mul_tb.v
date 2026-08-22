module edge_bf16_sig_mul_tb;
parameter FPGA_DSP_MUL = 0;
reg [7:0] activation_sig;
reg [7:0] weight_sig;
wire [15:0] product;

edge_bf16_sig_mul #(.FPGA_DSP_MUL(FPGA_DSP_MUL)) dut (
  .activation_sig_i(activation_sig),
  .weight_sig_i(weight_sig),
  .product_o(product)
);

task check;
  input [7:0] activation;
  input [7:0] weight;
  begin
    activation_sig = activation;
    weight_sig = weight;
    #1;
    if (product !== activation * weight) begin
      $display("FAIL activation=%h weight=%h got=%h expected=%h",
               activation, weight, product, activation * weight);
      $finish;
    end
  end
endtask

initial begin
  check(8'h00, 8'hff);
  check(8'h01, 8'h01);
  check(8'h80, 8'h7f);
  check(8'ha5, 8'h3c);
  check(8'hff, 8'hff);
  $display("TEST PASS edge_bf16_sig_mul FPGA_DSP_MUL=%0d", FPGA_DSP_MUL);
  $finish;
end
endmodule

