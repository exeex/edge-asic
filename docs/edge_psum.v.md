# `edge_psum`

## Purpose

`edge_psum` is the combinational BF16 partial-sum primitive shared by tensor
tiles. It computes one sanitized BF16 addition with round-to-nearest-even and
the tensor datapath's finite saturation policy.

The primitive is owned by `edge-asic`; product tiles and engines own the
number of lanes, accumulation schedule, storage, and response timing.

## Interface

- `a_raw[15:0]`: BF16 datapath result.
- `b_raw[15:0]`: BF16 partial sum.
- `y[15:0]`: BF16 sum.

The block contains no state or handshake. Tile and engine dimensions are owned
by its callers.
