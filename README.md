# edge-asic

`edge-asic` owns product-neutral accelerator and local-memory RTL shared by
Edge products. Products such as E3 and E4 select topology and scheduling policy
while consuming the same arithmetic and transport mechanisms from this tree.

The shared RTL includes ACTU, CMPU, accelerator stream/mux plumbing, generic
DMA read buffering and AXI-to-DTCM stream adaptation, the
canonical BF16 significand multiplier, dot8 arithmetic kernel, and BF16
partial-sum primitive used by both E3 and E4. The multiplier's `FPGA_DSP_MUL` parameter and
`EDGE_FPGA_DSP_MUL` define change FPGA mapping without changing the Verilog
hierarchy, arithmetic, or combinational latency.

Canonical source manifests are under `filelists/`. Product manifests consume
these sources while retaining ownership of product topology and scheduling.

Product repositories still own tile composition, descriptor scheduling,
Tensor/DTCM routing, and engine control. Implementation contracts and focused
tests for this shared RTL live in the private sibling `test-asic` project.
