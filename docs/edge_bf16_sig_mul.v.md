# `edge_bf16_sig_mul`

## Ownership and interface

This is the product-neutral unsigned BF16 significand multiplier leaf. E3
dot8 and E4 dot16 instantiate the same module so simulator, FPGA, and ASIC
flows verify one hierarchy.

- `activation_sig_i[7:0]`: unsigned activation significand.
- `weight_sig_i[7:0]`: unsigned weight significand or integer magnitude.
- `product_o[15:0]`: combinational unsigned product.

There is no state, valid signal, rounding, sign handling, or exponent handling.
Those belong to the consuming Tensor kernel. `FPGA_DSP_MUL=1` or the global
`EDGE_FPGA_DSP_MUL` define adds the `use_dsp` mapping attribute without adding
a pipeline boundary or changing arithmetic.

## Focused proof

`edge_bf16_sig_mul_tb.v` checks zero, unity, maximum, asymmetric operands, and
both parameter settings. The same source is compiled a third time with the
global FPGA define.

