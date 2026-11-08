# Convolution layer chaining on NHWC and NCHW RTL implementations

This project implements sequential convolution-layer chaining on two tiled RTL implementations: **NHWC and NCHW**. Successive layers execute on the same accelerator. Each layer reads the preceding layer's outputs from external memory.

Both implementations use a 10 × 10 systolic array, signed 8-bit inputs and weights, 32-bit accumulation and configuration, 8-bit local addresses, and 32-bit external addresses. Each layer uses identical tensors across implementations. Optional output quantization is configured independently for each layer.

The comparison covers cycle counts, time spent in each execution phase, FPGA resource use, timing estimates, and workload power and energy.

## Implementations

| Implementation | Approach |
| --- | --- |
| NHWC | Generates convolution windows using NHWC unrolling and per-lane activation feeders. |
| NCHW | Generates windows centrally using NCHW unrolling. The input buffer retains partially assembled vectors during SRAM bank-conflict retries and overlaps bank reads with array consumption. |

The current version adds descriptor-based chaining and output quantization to the previous version's tiled accelerators. The tile scheduler, core address generation, systolic feeding, precision, and local SRAM capacities remain unchanged.

The repository history documents the previous four-implementation comparison, which also included explicit im2col and im2collette FIFO.

## Layer chaining

The `conv_chain` top accepts one layer descriptor through a `descriptor_valid` / `descriptor_ready` handshake. Each descriptor supplies the convolution geometry, external-memory input/kernel/output base addresses, and quantization controls. The layer configuration source marks the final layer with `descriptor_last`.

Layers execute sequentially. Each layer completes its output writes before the next descriptor is accepted. There is no internal descriptor table or fixed layer-count limit.

```text
Layer configuration source
        │
        ▼
    conv_chain
        │
        ▼
 conv_accelerator ◄────► External memory
        │
        ▼
     conv_core
        │
        ▼
  10 × 10 PE array
```

The layer configuration source drives input wires carrying the geometry, memory addresses, quantization settings, and final-layer flag. The accelerator accepts these values on a rising clock edge when `descriptor_valid` and `descriptor_ready` are both high. The testbench currently supplies these signals and models external memory; both are outside the synthesized accelerator.

### Output quantization

Quantization applies to completed outputs during external-memory writes. Partial sums remain 32-bit throughout convolution.

Each layer selects:

- Quantization enabled or disabled.
- Right shift from 0 to 31.
- Arithmetic shifting or nearest rounding with halves away from zero.

Enabled quantization saturates the result to signed INT8 and sign-extends it into the existing 32-bit external word. Disabled quantization preserves the raw32 output.

One value occupies each external word. There is no packing or additional feature-map SRAM.

## Layers

The layer list includes one three-layer chain and four independent tests. The chain uses the first three convolution geometries from **MLPerf Tiny v1.1 ResNet8**. The independent tests use convolution geometries from PyTorch examples and tutorials.

| Workload / layer | Input C × H × W | Filters | Kernel / padding | Output K × P × Q | Test output mode and use |
| --- | --- | ---: | --- | --- | --- |
| Chain layer 1: stem convolution | 3 × 32 × 32 | 16 | 3 × 3 / 1 | 16 × 32 × 32 | INT8, shift 3, nearest; feeds chain layer 2. |
| Chain layer 2: first block convolution 1 | 16 × 32 × 32 | 16 | 3 × 3 / 1 | 16 × 32 × 32 | INT8, shift 5, nearest; feeds chain layer 3. |
| Chain layer 3: first block convolution 2 | 16 × 32 × 32 | 16 | 3 × 3 / 1 | 16 × 32 × 32 | Raw32; final chain output. |
| Independent: CIFAR10 tutorial conv1 | 3 × 32 × 32 | 6 | 5 × 5 / 0 | 6 × 28 × 28 | Raw32; checked independently. |
| Independent: CIFAR10 tutorial conv2 | 6 × 14 × 14 | 16 | 5 × 5 / 0 | 16 × 10 × 10 | Raw32; checked independently. |
| Independent: MNIST example conv1 | 1 × 28 × 28 | 32 | 3 × 3 / 0 | 32 × 26 × 26 | Raw32; checked independently. |
| Independent: historical MNISTConvNet tutorial conv2 | 10 × 12 × 12 | 20 | 5 × 5 / 0 | 20 × 8 × 8 | Raw32; checked independently. |

All layers use batch size 1, stride 1, and dilation 1. Padding is applied equally to height and width. Nearest rounding uses halves away from zero.

ResNet8 supplies the convolution geometries. The shifts of 3 and 5 are settings chosen for these synthetic test tensors; they are not taken from the model's trained quantization parameters.

The chain exchanges outputs through two external-memory regions used alternately for inputs and outputs. Each intermediate contains **16,384 words**, exceeding the **2,560-word local input capacity**. The next layer reads the values written by the preceding layer; reference outputs do not replace those memory contents.

The four independent layers are separate tests. Their raw32 outputs are not connected to subsequent layers. The two MNIST geometries come from different models.

Inputs and weights are deterministic synthetic integers, rather than trained model operands. Accumulation wraps to 32 bits. The tests cover convolution without bias, activation, normalization, pooling, or residual addition. The ResNet8 sequence ends before the first residual addition. These tests do not measure classification accuracy.

## Results

**Both chaining implementations have completed fresh synthesis for Nexys Video.** Accepted RTL validation covers all eight independent raw-output cases and both three-layer chains.

The output quantizer also passed **13,472 input-and-control test cases per architecture**. Each case supplies a signed 32-bit accumulator value, quantization enable, shift, and rounding mode, then checks the result against the integer reference. The cases cover shifts 0–31, both rounding modes, disabled quantization, positive and negative values, rounding boundaries, saturation boundaries, and random values. These are checks of the quantizer's arithmetic behavior, not additional convolution layers.

Synthesized-netlist workload measurements are still running. The NHWC whole-chain measurements at 1 MHz and its estimated Fmax have passed output, interface, cycle, native-activity, and power checks.

The measurement matrix contains:

- **4 whole-chain cases:** two architectures at 1 MHz and each design's estimated Fmax.
- **16 raw independent-layer cases:** four layers, two architectures, and two frequencies.
- **16 previous-version control cases:** matching accepted measurements reused after source, settings, tensor, netlist, capture, output, and power verification.

- [Current measurement snapshot](reports/chaining/README.md): accepted results, raw reports and source/hardware identities.
- [Reproduction tools](tools/chaining/README.md): source checks, RTL replay and native workload measurements.
- [Previous-version report](reports/README.md): the earlier four-implementation comparison.

Resource and timing results use Vivado 2026.1 post-synthesis analysis for the Nexys Video Artix-7 **`xc7a200tsbg484-1`**, with rebuilt hierarchy, two synthesis threads, a 20 ns clock constraint, and 2 ns input/output delays.

Workload activity is captured natively with XSim SAIF. Synthesized-netlist simulations check outputs and meaningful interface transfers against the reference RTL. Activity covers accepted start through final completion, excluding reset, tensor preload, and output export.

These are post-synthesis timing and power estimates. Power reports are rounded to 1 mW and have incomplete activity annotation. External-memory power is excluded.

## Credits

The systolic-array foundation includes [kaggar11/systolic_4x4arr](https://github.com/kaggar11/systolic_4x4arr). The NHWC algorithmic reference is Zhou et al., *Characterizing and Demystifying the Implicit Convolution Algorithm on Commercial Matrix-Multiplication Accelerators*. The implementation READMEs describe the source credits, and `conv_golden.py` includes the course and reference-model attribution.

Codex and GPT-6.1 Sol contributed to project development and tooling.

## TLDR

**Table key:** `TBD` marks a current measurement that is not yet available. `N/A` marks a comparison without an equivalent measurement, or a relative change with a zero reference value. Neither means zero.

Resource and independent-layer tables compare the previous unchained version on its previous target, the previous unchained version on Nexys Video, and the current chained version on Nexys Video. Whole-chain tables show the current version, since an equivalent previous measurement is unavailable. Target change compares the first two configurations; chaining change compares the two Nexys Video configurations.

Previous-version measurements use accepted native results. Current cycle counts use accepted RTL validation, and current latency values are calculated from those counts and the configured clock periods. Current power and energy cells contain accepted native results where available and `TBD` otherwise.

### Resources and timing: previous and current versions

Each architecture has three configurations: the previous unchained version on the previous FPGA target, the same unchained version on Nexys Video, and the current chained version on Nexys Video.

**Device use (%)** is the resource count divided by the FPGA's available resource count, multiplied by 100. Resource cells show the count followed by device use in parentheses, for example `18,765 (13.94%)`.

**Change (%)** is `(new value − previous value) / previous value × 100`. The first change column compares the unchained Nexys Video version with the previous-target version. The second compares the chained Nexys Video version with the unchained Nexys Video version. These are relative changes, not percentage-point differences in device use. Positive resource changes mean more hardware; negative changes mean less. Positive Fmax changes mean a higher estimated frequency.

WNS changes are shown in nanoseconds because a relative percentage of negative slack is difficult to interpret. A positive WNS change means slack improved.

#### NHWC

| Metric | Previous target, unchained | Nexys Video, unchained | Change from previous target | Nexys Video, chained | Change from Nexys Video unchained |
| --- | ---: | ---: | ---: | ---: | ---: |
| LUTs | 18,765 (13.94%) | 18,792 (13.96%) | +0.14% | **19,108 (14.20%)** | +1.68% |
| Flip-flops | 9,900 (3.68%) | 9,900 (3.68%) | +0.00% | **9,908 (3.68%)** | +0.08% |
| BRAM tiles | 15 (4.11%) | 15 (4.11%) | +0.00% | **15 (4.11%)** | +0.00% |
| DSPs | 111 (15.00%) | 111 (15.00%) | +0.00% | **111 (15.00%)** | +0.00% |
| WNS at 50 MHz (ns) | -1.584 | -5.918 | -4.334 ns | **-5.918** | +0.000 ns |
| Estimated Fmax (MHz) | 46.331 | 38.583 | -16.72% | **38.583** | +0.00% |

#### NCHW

| Metric | Previous target, unchained | Nexys Video, unchained | Change from previous target | Nexys Video, chained | Change from Nexys Video unchained |
| --- | ---: | ---: | ---: | ---: | ---: |
| LUTs | 60,966 (45.29%) | 61,055 (45.36%) | +0.15% | **60,980 (45.30%)** | -0.12% |
| Flip-flops | 17,995 (6.68%) | 17,995 (6.68%) | +0.00% | **17,997 (6.69%)** | +0.01% |
| BRAM tiles | 15 (4.11%) | 15 (4.11%) | +0.00% | **15 (4.11%)** | +0.00% |
| DSPs | 206 (27.84%) | 206 (27.84%) | +0.00% | **206 (27.84%)** | +0.00% |
| WNS at 50 MHz (ns) | -11.345 | -17.611 | -6.266 ns | **-17.608** | +0.003 ns |
| Estimated Fmax (MHz) | 31.903 | 26.588 | -16.66% | **26.590** | +0.01% |

Both current designs fit by resource counts. Neither meets the 50 MHz synthesis target. Estimated Fmax is derived from synthesis slack.

The previous target and Nexys Video differ in both package and speed grade. Comparing the unchained version across targets shows that transition. Comparing versions on Nexys Video shows chaining and quantization overhead. BRAM and DSP counts are unchanged, and estimated timing is essentially unchanged by chaining. The small NCHW LUT reduction reflects synthesis mapping and does not establish a general resource saving from adding chaining.

### Measurement clocks

Values are **MHz**. At own estimated Fmax, each configuration uses its own clock. Pending current measurements show their configured clock, calculated from the synthesis-derived period and rounded to the simulation clock grid.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — 1 MHz | 1.000000 | 1.000000 | 0.00% | 1.000000 | 0.00% |
| NHWC — own estimated Fmax | 46.330615 | 38.583224 | -16.72% | 38.583224 | 0.00% |
| NCHW — 1 MHz | 1.000000 | 1.000000 | 0.00% | 1.000000 | 0.00% |
| NCHW — own estimated Fmax | 31.903015 | 26.587259 | -16.66% | 26.588673 | +0.01% |

### Whole-chain cycles and latency

The previous unchained version has no equivalent accepted whole-chain measurement. Current cycle counts come from accepted RTL validation.

| Workload / metric | Nexys Video, chained |
| --- | ---: |
| NHWC — cycles | 1,000,554 |
| NHWC — latency at 1 MHz (ms) | 1000.554 |
| NHWC — latency at own estimated Fmax (ms) | 25.932 |
| NCHW — cycles | 1,014,911 |
| NCHW — latency at 1 MHz (ms) | 1014.911 |
| NCHW — latency at own estimated Fmax (ms) | 38.171 |

### Whole-chain workload power

Value cells show **dynamic / static / total power in mW**.

| Workload / metric | Nexys Video, chained |
| --- | ---: |
| NHWC — 1 MHz | 1.000 / 123.000 / 124.000 |
| NHWC — own estimated Fmax | 33.000 / 123.000 / 156.000 |
| NCHW — 1 MHz | TBD / TBD / TBD |
| NCHW — own estimated Fmax | TBD / TBD / TBD |

### Whole-chain estimated energy

Value cells show **dynamic / static / total energy in mJ**.

| Workload / metric | Nexys Video, chained |
| --- | ---: |
| NHWC — 1 MHz | 1.001 / 123.068 / 124.069 |
| NHWC — own estimated Fmax | 0.856 / 3.190 / 4.045 |
| NCHW — 1 MHz | TBD / TBD / TBD |
| NCHW — own estimated Fmax | TBD / TBD / TBD |

Both accepted NHWC captures cover **1,000,554 cycles** and have **87% matched-net activity annotation**. Whole-chain energy covers the complete three-layer sequence. Individual chain-layer cycles and latency are available, but energy is measured for the complete chain.

### Independent-layer cycle counts

Current values use accepted RTL validation. Each independent layer uses raw32 output.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 96,353 | 96,353 | 0.00% | 96,353 | 0.00% |
| NHWC — CIFAR10 conv2 | 83,913 | 83,913 | 0.00% | 83,913 | 0.00% |
| NHWC — MNIST conv1 | 121,714 | 121,714 | 0.00% | 121,714 | 0.00% |
| NHWC — Historical MNISTConvNet conv2 | 113,697 | 113,697 | 0.00% | 113,697 | 0.00% |
| NCHW — CIFAR10 conv1 | 74,722 | 74,722 | 0.00% | 74,722 | 0.00% |
| NCHW — CIFAR10 conv2 | 79,174 | 79,174 | 0.00% | 79,174 | 0.00% |
| NCHW — MNIST conv1 | 86,913 | 86,913 | 0.00% | 86,913 | 0.00% |
| NCHW — Historical MNISTConvNet conv2 | 115,194 | 115,194 | 0.00% | 115,194 | 0.00% |

### Independent-layer latency at 1 MHz

Values are **milliseconds**. Current values are calculated from accepted RTL cycles.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 96.353 | 96.353 | 0.00% | 96.353 | 0.00% |
| NHWC — CIFAR10 conv2 | 83.913 | 83.913 | 0.00% | 83.913 | 0.00% |
| NHWC — MNIST conv1 | 121.714 | 121.714 | 0.00% | 121.714 | 0.00% |
| NHWC — Historical MNISTConvNet conv2 | 113.697 | 113.697 | 0.00% | 113.697 | 0.00% |
| NCHW — CIFAR10 conv1 | 74.722 | 74.722 | 0.00% | 74.722 | 0.00% |
| NCHW — CIFAR10 conv2 | 79.174 | 79.174 | 0.00% | 79.174 | 0.00% |
| NCHW — MNIST conv1 | 86.913 | 86.913 | 0.00% | 86.913 | 0.00% |
| NCHW — Historical MNISTConvNet conv2 | 115.194 | 115.194 | 0.00% | 115.194 | 0.00% |

### Independent-layer workload power at 1 MHz

Value cells show **dynamic / static / total power in mW**. Change cells show the corresponding three relative percentage changes.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 1.000 / 123.000 / 124.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — CIFAR10 conv2 | 1.000 / 123.000 / 124.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — MNIST conv1 | 1.000 / 123.000 / 124.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — Historical MNISTConvNet conv2 | 1.000 / 123.000 / 124.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv1 | 1.000 / 123.000 / 124.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv2 | 1.000 / 123.000 / 123.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / +0.81% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — MNIST conv1 | 1.000 / 123.000 / 123.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / +0.81% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — Historical MNISTConvNet conv2 | 1.000 / 123.000 / 123.000 | 1.000 / 123.000 / 124.000 | 0.00% / 0.00% / +0.81% | TBD / TBD / TBD | TBD / TBD / TBD |

### Independent-layer estimated energy at 1 MHz

Value cells show **dynamic / static / total energy in mJ**. Change cells show the corresponding three relative percentage changes.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 0.096 / 11.851 / 11.948 | 0.096 / 11.851 / 11.948 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — CIFAR10 conv2 | 0.084 / 10.321 / 10.405 | 0.084 / 10.321 / 10.405 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — MNIST conv1 | 0.122 / 14.971 / 15.093 | 0.122 / 14.971 / 15.093 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — Historical MNISTConvNet conv2 | 0.114 / 13.985 / 14.098 | 0.114 / 13.985 / 14.098 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv1 | 0.075 / 9.191 / 9.266 | 0.075 / 9.191 / 9.266 | 0.00% / 0.00% / 0.00% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv2 | 0.079 / 9.738 / 9.738 | 0.079 / 9.738 / 9.818 | 0.00% / 0.00% / +0.81% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — MNIST conv1 | 0.087 / 10.690 / 10.690 | 0.087 / 10.690 / 10.777 | 0.00% / 0.00% / +0.81% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — Historical MNISTConvNet conv2 | 0.115 / 14.169 / 14.169 | 0.115 / 14.169 / 14.284 | 0.00% / 0.00% / +0.81% | TBD / TBD / TBD | TBD / TBD / TBD |

### Independent-layer latency at own estimated Fmax

Values are **milliseconds**. Current values are calculated from accepted RTL cycles.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 2.080 | 2.497 | +20.08% | 2.497 | 0.00% |
| NHWC — CIFAR10 conv2 | 1.811 | 2.175 | +20.08% | 2.175 | 0.00% |
| NHWC — MNIST conv1 | 2.627 | 3.155 | +20.08% | 3.155 | 0.00% |
| NHWC — Historical MNISTConvNet conv2 | 2.454 | 2.947 | +20.08% | 2.947 | 0.00% |
| NCHW — CIFAR10 conv1 | 2.342 | 2.810 | +19.99% | 2.810 | -0.01% |
| NCHW — CIFAR10 conv2 | 2.482 | 2.978 | +19.99% | 2.978 | -0.01% |
| NCHW — MNIST conv1 | 2.724 | 3.269 | +19.99% | 3.269 | -0.01% |
| NCHW — Historical MNISTConvNet conv2 | 3.611 | 4.333 | +19.99% | 4.332 | -0.01% |

### Independent-layer workload power at own estimated Fmax

Value cells show **dynamic / static / total power in mW**. Change cells show the corresponding three relative percentage changes.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 41.000 / 123.000 / 164.000 | 34.000 / 123.000 / 157.000 | -17.07% / 0.00% / -4.27% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — CIFAR10 conv2 | 38.000 / 123.000 / 161.000 | 31.000 / 123.000 / 155.000 | -18.42% / 0.00% / -3.73% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — MNIST conv1 | 41.000 / 123.000 / 164.000 | 34.000 / 123.000 / 157.000 | -17.07% / 0.00% / -4.27% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — Historical MNISTConvNet conv2 | 36.000 / 123.000 / 159.000 | 30.000 / 123.000 / 153.000 | -16.67% / 0.00% / -3.77% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv1 | 24.000 / 123.000 / 147.000 | 20.000 / 123.000 / 143.000 | -16.67% / 0.00% / -2.72% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv2 | 21.000 / 123.000 / 144.000 | 18.000 / 123.000 / 141.000 | -14.29% / 0.00% / -2.08% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — MNIST conv1 | 21.000 / 123.000 / 143.000 | 17.000 / 123.000 / 140.000 | -19.05% / 0.00% / -2.10% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — Historical MNISTConvNet conv2 | 20.000 / 123.000 / 143.000 | 17.000 / 123.000 / 140.000 | -15.00% / 0.00% / -2.10% | TBD / TBD / TBD | TBD / TBD / TBD |

### Independent-layer estimated energy at own estimated Fmax

Value cells show **dynamic / static / total energy in mJ**. Change cells show the corresponding three relative percentage changes.

| Workload / metric | Previous target, unchained | Nexys Video, unchained | Target change | Nexys Video, chained | Chaining change |
| --- | ---: | ---: | ---: | ---: | ---: |
| NHWC — CIFAR10 conv1 | 0.085 / 0.256 / 0.341 | 0.085 / 0.307 / 0.392 | -0.42% / +20.08% / +14.95% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — CIFAR10 conv2 | 0.069 / 0.223 / 0.292 | 0.067 / 0.268 / 0.337 | -2.04% / +20.08% / +15.60% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — MNIST conv1 | 0.108 / 0.323 / 0.431 | 0.107 / 0.388 / 0.495 | -0.42% / +20.08% / +14.95% | TBD / TBD / TBD | TBD / TBD / TBD |
| NHWC — Historical MNISTConvNet conv2 | 0.088 / 0.302 / 0.390 | 0.088 / 0.362 / 0.451 | +0.07% / +20.08% / +15.55% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv1 | 0.056 / 0.288 / 0.344 | 0.056 / 0.346 / 0.402 | -0.01% / +19.99% / +16.73% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — CIFAR10 conv2 | 0.052 / 0.305 / 0.357 | 0.054 / 0.366 / 0.420 | +2.85% / +19.99% / +17.49% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — MNIST conv1 | 0.057 / 0.335 / 0.390 | 0.056 / 0.402 / 0.458 | -2.86% / +19.99% / +17.48% | TBD / TBD / TBD | TBD / TBD / TBD |
| NCHW — Historical MNISTConvNet conv2 | 0.072 / 0.444 / 0.516 | 0.074 / 0.533 / 0.607 | +1.99% / +19.99% / +17.48% | TBD / TBD / TBD | TBD / TBD / TBD |

Energy equals reported power multiplied by workload latency. Power components and totals are rounded independently, so displayed components may not sum exactly to the total. Percentages use the underlying values before display rounding. Own-Fmax comparisons include different operating clocks.

All independent layers are measured separately; their outputs are not fed into subsequent tests.
