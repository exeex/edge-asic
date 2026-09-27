# Fragmented SRAM prototype

## Layer ownership

This directory owns SRAM storage and reusable H1/H2/H4 compositions. It does
not define DTCM client protocols or product compatibility wrappers. E3's
`edge_dtcm_h4_wrapper` lives in `edge-e3/edge_dtcm_subsys/rtl`; E4's
`edge_e4_dtcm_h4_wrapper` and `edge_e4_dtcm_legacy_sram_wrapper` live in
`edge-e4/edge_dtcm_subsys/rtl`. DTCM owns address/phase translation and
response tags and instantiates these SRAM units.

The inferred SRAM model `edge_dtcm_spsram_1024x64` is stored here as well.
Its historical module name is retained as the OpenROAD macro replacement
key; it contains only the memory behavior, with no DTCM routing.

## Phase-butterfly H4 compatibility path

`edge_sram_h4_tile32k` is a separate functional composition of four 8 KiB
H2 tiles (64 `fakeram_512x8` macros).  Four such tiles plus
`edge_e4_dtcm_h4_wrapper` replace one legacy 128 KiB bank16 raw slice
without changing its address-to-byte mapping or 128 bytes/cycle maximum raw
width.  The wrapper owns channel/pair/byte/depth routing; the H1/H2/H4
children only perform their registered phase butterflies.  H2 now accepts a
one-bit per-byte half-route input so both H1 quartets are reachable, while
the physical 512x8 row pin remains 9 bits.

H4 has three sampling edges (H4, H2, H1/SRAM). The DTCM wrapper owns
the fourth edge: E3 registers the response, and E4 registers the request.
Both wrappers preserve four-edge client response latency.  Its 256-hop H1 phase chain requires a
256-clock reset/wake fill before the wrapper admits requests.  The E4 A/B
test checks functional compatibility and eight-route throughput; it is not
yet a hardened macro, product backend switch, APR timing result, or tensor
deskew integration.  The previously implemented 64 KiB-fragment path below
remains independent.

This independent shared-ASIC RTL is deliberately named `sram`, not `dtcm`.
One `edge_sram_quad64k` owns 64 KiB: four 128-bit pair positions, 1024 rows,
implemented by two `edge_sram_h1_array32k` depth halves (128
`fakeram_512x8` leaves in total).  Each 32 KiB half contains eight 4 KiB H1
tiles, 64 single-port macros, and no depth merge.  Their eight byte lanes
per tile are assigned to four pair positions and two adjacent bytes.  Address
bit 9 selects the 32 KiB half at the 64 KiB boundary; only bits 8:0 reach
the SRAM pins.  The one-wire H1 chain has 128 hops per 64 KiB fragment.

The compatibility shell `edge_e4_dtcm_legacy_sram_wrapper` replaces **one**
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
