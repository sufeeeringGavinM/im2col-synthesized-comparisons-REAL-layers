# Current accelerator decisions

The November 16 release promotes the accepted quantization-only RTL and preserves the original scheduler/core. The CNN update adds a captured ReLU enable and a combinational sign clamp on completed output writes. The frozen predecessor is Git commit `97e6f4a232c8c64792d3a033fcdcb5d5a10f2a9c`.

One shared completed-output postprocessor adds optional per-channel bias with ACC32 wrap, multiplies by an unsigned32 numerator using a full signed64 product, then rounds/shifts/clamps if requantization is enabled. Scale, bias, ReLU and geometry controls are captured on descriptor acceptance. Bias is independent of requantization bypass; partial sums are never narrowed. Output words remain unpacked and sign-extended.

`conv_program` fetches fixed-size descriptors over the SRAM-style backing-memory port and uses the existing `conv_chain` valid/ready interface. Fetch runs only between layers so the memory port needs no request arbitration during execution. The program advances by 27 words after each completed layer until the descriptor marked last. The exporter owns compatible geometry, bounds and next-layer addresses. ReLU runs on writeback when enabled in the descriptor.

Resource/timing/power claims refer to hash-matched accepted post-synthesis evidence. Main RTL is copied byte-for-byte from that snapshot. Packaging edits to runners/benches are checked separately; they do not establish new physical measurements.
