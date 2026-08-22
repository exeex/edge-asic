# `edge_dot8_kernel`

## Purpose

`edge_dot8_kernel` is the smallest arithmetic row in the Edge tensor core.
It computes one eight-element dot product and emits a BF22 partial together
with the existing bit-true BF16 compatibility result. The
neutral name reflects that the connected tensor path stores both BF16 WLD and
signed-I8 WLD data in a shared internal BF16 weight representation.

## Interface And Arithmetic

- `bf16_vec_i` supplies eight BF16 activations.
- `bf16_weight_vec_i` supplies eight BF16 weights when
  `weight_bf16_mode_i` is set.
- `int8_vec_i` remains the direct signed-I8 compatibility input when
  `weight_bf16_mode_i` is clear.
- `in_valid` advances the fixed-latency pipeline; `out_valid` qualifies
  `bf22_o` and the compatibility `bf16_o` result.
- `partial_valid_o` qualifies the signed 24-bit `partial_sum_o` and signed
  10-bit `partial_exp_o` directly after the s4 adder tree. These internal
  outputs let a wider kernel reconcile exponent domains before the dot8
  normalization stage; ordinary dot8 users leave them unconnected.
- `PARTIAL_ONLY=1` makes the normal BF22/BF16/RSUM outputs constant and allows
  synthesis to remove the s5 result packer for a wider composed kernel. The
  default is zero and preserves the standalone dot8 contract.
- `FPGA_DSP_ADD=1` preserves the arithmetic and pipeline timing while marking
  the s4 24-bit signed adder tree for Xilinx DSP SIMD packing. The default is
  zero for the generic logic implementation.
- `FPGA_DSP_MUL=1` selects the DSP-marked implementation of the canonical
  `edge-asic/rtl/tensor/edge_bf16_sig_mul.v` leaf. The leaf ports, unsigned
  8x8 arithmetic, hierarchy, and combinational timing boundary are identical
  to the generic variant.
  Defining `EDGE_FPGA_DSP_MUL` selects the same leaf implementation across a
  complete product build without changing or bypassing intermediate modules.
- `INPUTS_SANITIZED=1` lets a composed tile prove that activation and BF16
  weight inputs were sanitized at their shared ownership boundary. The default
  remains zero, so standalone E3 users retain the existing per-lane sanitize
  behavior.
- RSUM controls optionally accumulate consecutive dot products in the
  module-local BF22 accumulator and emit only the last result.

The normal operation is `sum(k=0..7, activation[k] * weight[k])`, using the
existing sanitize, exponent alignment, signed adder-tree, normalization, and
round-to-nearest-even behavior.

Exponent alignment keeps shifts zero through 16. A 16-bit unsigned
significand product can still round to one at shift 16, but at shift 17 its
maximum value is strictly below half an output LSB. Shifts 17 and above
therefore take the exact-zero path before the fine alignment mux; this is a
bit-true range reduction, not a precision approximation.

## Ownership

The arithmetic hierarchy is split by physical ownership:

- `edge_dot8_kernel` and its arithmetic pipeline are owned by `edge-asic`.
  E3 composes eight rows into its tile; E4 also reuses the kernel while owning
  its wider grouping and scheduling policy.

- `edge_bf16_sig_mul` is owned by `edge-asic` and shared by E3 dot8 and E4
  dot16. Technology selection is contained in that leaf so Verilator and FPGA
  synthesis elaborate the same surrounding hierarchy.
- `edge_dot_mul_lane` owns one lane's significand selection and sign when
  products are supplied directly. `EXTERNAL_PRODUCTS=1` lets a composed row
  combine its local 9-bit weight A/B storage and multiplier in one physical
  leaf and inject the registered product at the same pipeline boundary.
- The central exponent cluster is split into `edge_dot_product_exp` and
  `edge_dot_exp_max`. Per-lane product-exponent additions are registered before
  the balanced global-max tree, keeping the add and comparator tree in
  separate 1 GHz cycles. Mantissa products and signs take a matching delay
  register beside the central cluster.
- `edge_dot_align_lane_coarse` and `edge_dot_align_lane_fine` are two explicit
  lane-local stages forming a distributed shifter corridor between multiplier
  islands and the signed adder tree. They consume the shift distance from the
  central exponent domain and contain no exponent addition.

`EXTERNAL_WEIGHT_EXP=1` lets a composed physical row supply a centrally
buffered weight-exponent vector through `weight_exp_vec_i`. The default remains
zero for standalone dot8 users and derives exponent fields from the ordinary
BF16 weight vector. This selection changes no arithmetic semantics.

WLD, weight ping-pong selection, per-lane PSUM, and scale are owned by
`edge_tile8x8_unit`; they are not ports of this leaf unit.  That
wrapper instantiates eight `edge_dot8_unit` rows over one shared BF16x8 input.
No wider dot wrapper is part of the E3 tensor contract.
The partial interface does not change the BF22/BF16 result or RSUM behavior.

## Focused Tests

- `bf16_bf16_dot8_tb.v` checks BF16-weight dot products.
- `bf16_bf16_dot8_rsum_tb.v` checks BF22 RSUM behavior.
- `dot8_kernel_fpga_equiv_tb.v` compares generic and FPGA variants cycle by
  cycle in I8, BF16-weight, partial-result, and RSUM operation.
- `tile8x8_throughput_tb.v` checks the eight-row composed datapath.
