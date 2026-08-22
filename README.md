# edge-asic

`edge-asic` owns product-neutral accelerator and local-memory RTL shared by
Edge products. Products such as E3 and E4 select topology and scheduling policy
while consuming the same arithmetic and transport mechanisms from this tree.

The initial extraction is the canonical BF16 significand multiplier used by
both dot8 and dot16. Its `FPGA_DSP_MUL` parameter and `EDGE_FPGA_DSP_MUL`
define change FPGA mapping without changing the Verilog hierarchy, arithmetic,
or combinational latency.

