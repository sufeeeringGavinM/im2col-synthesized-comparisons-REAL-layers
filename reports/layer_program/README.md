# Memory-backed layer program results

These measurements were captured on the published `c7634fc` build, which
samples the launch-time descriptor base. The official local update defaults
to word address 0 and reproduced its cycles, resource counts and estimated
setup timing. The [address-zero validation](../address_zero/README.md) also reproduced the reported power and energy.

NHWC and two-slot NCHW each matched all 2,106 outputs per image on 20 Florida MNIST CNN images
and classified 20/20 correctly. Each layout also passed three directed cases and the original
Dense replay. The directed restart check launched again from a different descriptor base.
The independent Integer model matched all 100,000 retained logits on 10,000 images.

| Metric | NHWC | NCHW |
|---|---:|---:|
| Accelerator layer cycles | 132,353 | 96,169 |
| Start-to-done cycles | 132,472 | 96,288 |
| Descriptor reads | 108 | 108 |
| Descriptor fetch and launch cycles | 119 | 119 |
| Previous streamed-descriptor chain cycles | 132,359 | 96,175 |
| Start-to-done cycle increase | +113 (0.085%) | +113 (0.117%) |
| Slice LUTs (change from ReLU release) | 21,552 (+97, +0.45%) | 61,935 (+579, +0.94%) |
| Slice registers (change from ReLU release) | 10,985 (+688, +6.68%) | 18,848 (+660, +3.63%) |
| BRAM tiles (change from ReLU release) | 10 (+0, +0.00%) | 15 (+0, +0.00%) |
| DSPs (change from ReLU release) | 115 (+0, +0.00%) | 215 (+0, +0.00%) |
| 20 MHz setup WNS | +21.381 ns | +12.391 ns |
| Estimated Fmax (change from ReLU release) | 34.942 MHz (+0.00%) | 26.589 MHz (+0.02%) |
| Chain latency at 20 MHz | 6.62360 ms | 4.81440 ms |
| Dynamic / static / total at 20 MHz | 14 / 123 / 136 mW | 12 / 123 / 135 mW |
| Estimated energy at 20 MHz | 0.901 mJ | 0.650 mJ |
| SAIF annotated nets at 20 MHz | 87%   (59824/68557) | 85%   (162124/189900) |
| Chain latency at own estimated Fmax | 3.79135 ms | 3.62139 ms |
| Dynamic / static / total at own estimated Fmax | 24 / 123 / 147 mW | 16 / 123 / 139 mW |
| Estimated energy at own estimated Fmax | 0.557 mJ | 0.503 mJ |
| SAIF annotated nets at own estimated Fmax | 87%   (59824/68557) | 85%   (162124/189900) |

The matched host-ReLU controls produced the same layer outputs, phases, jobs, memory transfers
and layer cycle counts as the new top. The program spends 119 cycles on fetch and launch,
including four 27-word reads. The previous window started at first descriptor acceptance
and included six inter-layer cycles. The new end-to-end window begins at the program start.

Vivado 2026.1 synthesized both tops out of context for Nexys Video
(`xc7a200tsbg484-1`) with a 20 ns target and 2 ns I/O delays. For each layout,
a zero-delay functional netlist reproduced the RTL memory transactions and outputs at 20 MHz
and at the layout's own post-synthesis estimated Fmax. Native XSim SAIF spans start through
chain completion. The estimates exclude external-memory and software energy.
Both timing and power describe the synthesized design.

- [RTL and layer phases](rtl_results.json), [Dense replay](dense_results.json), and [host ReLU controls](host_relu_control.json)
- [Independent integer results](independent_integer.json)
- [Native netlist timing and power](native_results.json) and [utilization](utilization.json)
- [Source, fixture and capture identities](source_and_capture_identity.json)
- [Prior streamed-descriptor ReLU release](../mnist_cnn_relu/README.md)
