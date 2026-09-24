# Fragmented SRAM prototype

This independent shared-ASIC RTL is deliberately named `sram`, not `dtcm`.
One `edge_sram_quad64k` owns 64 KiB: four 128-bit pair positions, 1024 rows,
implemented by two `edge_sram_h1_array32k` depth halves (128
`fakeram_512x8` leaves in total).  Each 32 KiB half contains eight 4 KiB H1
tiles, 64 single-port macros, and no depth merge.  Their eight byte lanes
per tile are assigned to four pair positions and two adjacent bytes.  Address
bit 9 selects the 32 KiB half at the 64 KiB boundary; only bits 8:0 reach
the SRAM pins.  The one-wire H1 chain has 128 hops per 64 KiB fragment.

The compatibility shell `edge_sram_legacy_bank16_wrapper` replaces **one**
legacy 128 KiB bank16 raw slice with two 64 KiB fragments.  The two existing
E4 slices would therefore become four fragments without changing 256 KiB
capacity.  For the existing byte offset:

```
legacy slice         = offset[4]
fragment within slice = offset[5]
fragment local pair   = offset[7:6]
row                   = offset[17:8]
byte within pair      = offset[3:0]
```

Four successive 16-byte beats span all four fragments; that is the intended
foundation for one 16-lane FP32 vector.  No six-channel tensor protocol or
FP32 packing/psum implementation is implied by this mapping alone.  The
compatibility wrapper preserves the existing four upper and four lower raw
routes *per legacy slice*, their fixed windows, byte strobes, and four-edge
read latency.  The wrapper owns the legacy H4 permutation, each fragment
registers its already-selected local pair boundary (H2 timing cut), and each
4 KiB tile registers H1.  Physically local H2 and H4 muxes within the 32 KiB
boundary remain to be designed.
It does not queue/retry requests or lend an idle SRAM phase.

This is equivalence-first RTL, **not a hardened 64 KiB macro**.  Its phase
chain initializes every hop to the canonical zero phase so requests legal at
the old 40-cycle wake boundary are accepted.  Reset cost, tile pin ownership,
parent H2 routing, CTS, detailed route, and six-channel scheduling require
separate physical and protocol experiments before product substitution.
