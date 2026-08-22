# edge-asic

`edge-asic` owns product-neutral accelerator and local-memory RTL shared by
Edge products. Products such as E3 and E4 select topology and scheduling policy
while consuming the same arithmetic and transport mechanisms from this tree.

The initial Tensor extraction contains the canonical BF16 significand
multiplier and dot8 arithmetic kernel used by both E3 and E4. The multiplier's
`FPGA_DSP_MUL` parameter and `EDGE_FPGA_DSP_MUL` define change FPGA mapping
without changing the Verilog hierarchy, arithmetic, or combinational latency.

Product repositories still own tile composition, descriptor scheduling,
Tensor/DTCM routing, and engine control. During migration, existing E3/E4
private tests continue to prove the shared kernel until their common tests are
moved to a dedicated private edge-asic test project.
