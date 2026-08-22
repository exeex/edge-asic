// Canonical unsigned significand multiplier shared by Edge Tensor products.
// FPGA selection changes synthesis mapping only; arithmetic and latency stay
// identical for Verilator, FPGA synthesis, and ASIC implementation.
module edge_bf16_sig_mul #(
  parameter FPGA_DSP_MUL = 0
)(
  input  [7:0]  activation_sig_i,
  input  [7:0]  weight_sig_i,
  output [15:0] product_o
);
localparam USE_FPGA_DSP_MUL = FPGA_DSP_MUL
`ifdef EDGE_FPGA_DSP_MUL
  || 1
`endif
  ;
generate
  if (USE_FPGA_DSP_MUL) begin : gen_fpga_dsp_mul
    (* use_dsp = "yes" *) wire [15:0] dsp_product =
      activation_sig_i * weight_sig_i;
    assign product_o = dsp_product;
  end else begin : gen_logic_mul
    assign product_o = activation_sig_i * weight_sig_i;
  end
endgenerate
endmodule

