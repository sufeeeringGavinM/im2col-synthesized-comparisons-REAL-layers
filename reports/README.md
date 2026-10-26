# Real model geometries on accepted tiled address-counter hardware

State: MEASUREMENTS_COMPLETE; RTL 16/16; native SAIF/power 16/16.

N=1, groups=1, dilation=1. Signed8 synthetic operands; 32-bit wrapped sums. This studies individual convolution geometries, with no bias, normalization, activation, pooling, shortcut, trained weights or accuracy claim.

## Reused post-synthesis hardware

Vivado2026.1 / xc7a200tfbg676-2 / OOC rebuilt hierarchy / two threads / array10 / CFG32 / 20ns target / 2ns I/O. Exact source/netlist/DCP hashes are in [hardware provenance](hardware_provenance.json). No resynthesis. All resource counts fit and existing1MHz checks pass; all four miss50MHz. Estimated Fmax is1000/(20-WNS); no placement/routing or board measurement. CFGBVS-1 and DSP pipeline recommendations remain. No missing-clock/unconstrained-internal-endpoint issues in the accepted checks.

| Design | WNS ns | Estimated Fmax MHz | LUT count (%) | FF count (%) | BRAM tiles (%) | DSP count (%) | Separate vectorless dynamic/static/total W |
|---|---:|---:|---:|---:|---:|---:|---|
|channel_first|-1.584|46.330615271|18765 (13.94)|9900 (3.68)|15 (4.11)|111 (15.00)|0.002/0.123/0.125|
|centralized|-11.345|31.903014835|60966 (45.29)|17995 (6.68)|15 (4.11)|206 (27.84)|0.013/0.123/0.136|
|explicit|-2.397|44.648836898|21540 (16.00)|11412 (4.24)|175 (47.95)|171 (23.11)|0.008/0.130/0.138|
|im2collette_fifo|-9.409|34.003196300|30640 (22.76)|14423 (5.36)|20 (5.48)|111 (15.00)|0.003/0.123/0.126|

## New full-layer cycles

Window: accepted start through final output store/done; includes planning/setup, every serialized transfer, repeated core jobs and transitions. Excludes reset, tensor preload, reference computation and export. Six phases are exclusive and sum exactly. Nested core im2col/weights/advances/stalls/transitions subdivide core work; retries overlap and must not be added.

| Design | Layer | Cycles | Plan | Input | Kernel | Core | Output | Transition | Tiles | Core jobs |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|centralized|cifar10_conv1|74722|606|26880|25200|12600|9408|28|28|28|
|centralized|cifar10_conv2|79174|434|16800|48000|10720|3200|20|20|20|
|centralized|mnist_conv1|86913|1841|17472|14976|9256|43264|104|104|104|
|centralized|mnist_legacy_conv2|115194|362|19200|80000|13056|2560|16|16|16|
|channel_first|cifar10_conv1|96353|89|26880|25200|34748|9408|28|28|28|
|channel_first|cifar10_conv2|83913|73|16800|48000|15820|3200|20|20|20|
|channel_first|mnist_conv1|121714|242|17472|14976|45656|43264|104|104|104|
|channel_first|mnist_legacy_conv2|113697|65|19200|80000|11856|2560|16|16|16|
|explicit|cifar10_conv1|136337|89|26880|25200|74732|9408|28|28|28|
|explicit|cifar10_conv2|94473|73|16800|48000|26380|3200|20|20|20|
|explicit|mnist_conv1|171634|242|17472|14976|95576|43264|104|104|104|
|explicit|mnist_legacy_conv2|120545|65|19200|80000|18704|2560|16|16|16|
|im2collette_fifo|cifar10_conv1|96325|89|26880|25200|34720|9408|28|28|28|
|im2collette_fifo|cifar10_conv2|83893|73|16800|48000|15800|3200|20|20|20|
|im2collette_fifo|mnist_conv1|121610|242|17472|14976|45552|43264|104|104|104|
|im2collette_fifo|mnist_legacy_conv2|113681|65|19200|80000|11840|2560|16|16|16|

## Native workload power at actual1MHz

XSim open_saif/log_saif/close_saif, scope /tb_conv_core/GATE only. Backing memory and shadow RTL excluded. Exact full-layer duration must equal accepted cycles times1us; gate controls, enables, enabled external addresses/data checked cycle-by-cycle and final outputs checked exactly. Zero-delay synthesized simulation excludes routed glitches. Power is quantized to1mW; static dominates at1MHz; no matched-baseline savings claim.

| Design | Layer | Cycles | Dynamic W | Static W | Total W | Energy uJ | Matched nets | Confidence |
|---|---|---:|---:|---:|---:|---:|---|---|
|centralized|cifar10_conv1|74722|0.001|0.123|0.124|9265.528|85%   (159563/187575)|High|
|centralized|cifar10_conv2|79174|0.001|0.123|0.123|9738.402|85%   (159563/187575)|High|
|centralized|mnist_conv1|86913|0.001|0.123|0.123|10690.298999999999|85%   (159563/187575)|High|
|centralized|mnist_legacy_conv2|115194|0.001|0.123|0.123|14168.862|85%   (159563/187575)|High|
|channel_first|cifar10_conv1|96353|0.001|0.123|0.124|11947.771999999999|89%   (57308/64661)|High|
|channel_first|cifar10_conv2|83913|0.001|0.123|0.124|10405.212|89%   (57308/64661)|High|
|channel_first|mnist_conv1|121714|0.001|0.123|0.124|15092.536|89%   (57308/64661)|High|
|channel_first|mnist_legacy_conv2|113697|0.001|0.123|0.124|14098.428|89%   (57308/64661)|High|
|explicit|cifar10_conv1|136337|0.005|0.13|0.135|18405.495000000003|84%   (67594/80261)|High|
|explicit|cifar10_conv2|94473|0.005|0.13|0.135|12753.855000000001|84%   (67594/80261)|High|
|explicit|mnist_conv1|171634|0.005|0.13|0.135|23170.59|84%   (67594/80261)|High|
|explicit|mnist_legacy_conv2|120545|0.005|0.13|0.135|16273.575|84%   (67594/80261)|High|
|im2collette_fifo|cifar10_conv1|96325|0.001|0.123|0.124|11944.3|72%   (66211/91612)|High|
|im2collette_fifo|cifar10_conv2|83893|0.001|0.123|0.124|10402.732|72%   (66211/91612)|High|
|im2collette_fifo|mnist_conv1|121610|0.001|0.123|0.124|15079.64|72%   (66211/91612)|High|
|im2collette_fifo|mnist_legacy_conv2|113681|0.001|0.123|0.124|14096.444|72%   (66211/91612)|High|

Latency seconds=cycles/1e6, throughput layers/s=1e6/cycles (N1), energy uJ=watts*cycles. Useful MAC/cycle uses valid non-padding input/kernel products; the CSV also provides nominal dense MACs including padded positions. These are workload measures; physical resource/timing figures describe unchanged hardware.

Batch sweep omitted: accepted existing batch correctness evidence is reused; the tiler invokes coreN1 serially without cross-image weight retention. Per-row, non-tiled designs and deferred SRAM-read evidence are excluded.

## Coverage, precision and runtime provenance

Matched design-net coverage is72–89%, not complete annotation. All16 tool reports give High confidence and meet1MHz timing under the reused post-synthesis constraints. Power components/totals are rounded independently to1mW; their displayed sum may differ by1mW. Energy uses the tool-reported total. Dynamic/static/total estimates remain distinct from the separate vectorless results and from board measurements.

[Validation and concurrency provenance](validation_engine.json), [RTL runtime records](rtl_runtime.json), [native session wall times](native_runtime.json), and [inherited cross-simulator validation](rtl_engine_migration.json) retain the exact execution scope. The current fourth case is the historical MNISTConvNet tutorial conv2, a different source model from the current-example MNISTconv1; these are separate layer geometries, not a connected network run. All operands are synthetic.

Raw original Vivado report command headers retain output-path metadata; portable reproduction has no dependency on those original paths. Native SAIF bytes are unchanged.
