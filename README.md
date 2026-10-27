# Convolution layer comparisons on four RTL implementations

This project tests four complete convolution layers on four tiled RTL implementations: **NHWC, centralized NCHW, explicit im2col, and im2collette FIFO**. It compares cycle counts, time spent in each execution phase, FPGA resource use, timing estimates, and workload power estimates.

All four implementations use the same common hardware settings: a 10 × 10 systolic array, signed 8-bit inputs and weights, 32-bit accumulation and configuration, 8-bit local addresses, and 32-bit external addresses. Each layer uses identical tensors across implementations. The implementations differ in how they generate and supply convolution data, including their buffering and scratch storage, so their resource use differs. Each implementation's synthesized hardware stays unchanged across the four layers.

## Implementations

| Implementation | Approach |
|---|---|
| [NHWC](tiled/NHWC/README.md) | Generates convolution windows using NHWC unrolling. |
| [Centralized NCHW](tiled/NCHW_centralized/README.md) | Generates windows centrally using NCHW unrolling. Two activation-vector slots retain partially assembled vectors during SRAM bank-conflict retries and overlap bank reads with array consumption. |
| [Explicit im2col](tiled/explicit/README.md) | Materializes convolution windows in scratch memory before computation. |
| [im2collette FIFO](tiled/im2collette_fifo/README.md) | Supplies convolution data through two eight-value packets per input channel, with prefetching and pipelining. |

## Layers

These are full convolution layer geometries from official PyTorch examples and tutorials. Every filter and valid output position is tested.

| Layer | Input C × H × W | Filters | Kernel | Output K × P × Q | What it demonstrates |
|---|---|---|---|---|---|
| CIFAR10 tutorial conv1 | 3 × 32 × 32 | 6 | 5 × 5 | 6 × 28 × 28 | Low input-channel count, overlapping windows, and partial use of the 10-wide array. |
| CIFAR10 tutorial conv2 | 6 × 14 × 14 | 16 | 5 × 5 | 16 × 10 × 10 | Multi-channel accumulation and output-channel tiling with a partial final filter tile. |
| MNIST example conv1 | 1 × 28 × 28 | 32 | 3 × 3 | 32 × 26 × 26 | Single-channel window generation and the cost of storing a large output tensor. |
| Historical MNISTConvNet tutorial conv2 | 10 × 12 × 12 | 20 | 5 × 5 | 20 × 8 × 8 | Channel reduction, full filter tiles, and dominant weight-transfer cost. |

All layers use batch size 1, stride 1, no padding, and dilation 1. Every output filter uses all input channels (`groups=1`). The two MNIST layers come from different models; they are separate tests.

Inputs and weights are deterministic synthetic integers, rather than trained model operands. Accumulation wraps to 32 bits. The tests cover convolution only, without bias, activation, normalization, or pooling. They do not measure classification accuracy. [Layer definitions and model sources](tools/workloads/README.md) are included.

## Results

**All 16 RTL tests and all 16 synthesized-netlist activity and power tests passed.** Outputs are checked against golden references, and synthesized-netlist simulations also check interface behavior and cycle counts.

- [Results summary](reports/README.md): cycle counts, execution phases, FPGA resources, timing, and power.
- [Cycle data](reports/cycle_results.csv): total cycles, planning, input transfers, weight transfers, computation, output transfers, and transitions.
- [Workload power data](reports/workload_results.csv): dynamic, static, and total power estimates, energy, and activity annotation coverage.
- [Reproduction tools](tools/README.md): tensor generation, RTL validation, and Vivado/XSim commands.

Centralized NCHW has the lowest cycle count for the first three layers; im2collette FIFO narrowly leads for historical MNISTConvNet conv2.

Resource and timing results use Vivado 2026.1 post-synthesis analysis for the Artix-7 `xc7a200tfbg676-2`. All four designs fit the device and meet the common 1 MHz power-analysis clock; none meets the 50 MHz synthesis target. Workload activity is captured natively with XSim SAIF. Power estimates are dominated by static power, rounded to 1 mW, and have incomplete activity annotation. They are post-synthesis estimates, not routed or measured board power. Full measurement details and source/hardware identity records are included with the reports.

## Credits

Source and algorithm credits, course attribution, and AI disclosures are retained in the implementation directories. Sources include [kaggar11/systolic_4x4arr](https://github.com/kaggar11/systolic_4x4arr), [jmbino/im2col](https://github.com/jmbino/im2col), and [ckmalangen/im2collette](https://github.com/ckmalangen/im2collette). See the [NHWC credits](tiled/NHWC/README.md#credits) for the Zhou et al. algorithmic reference. Codex and GPT-6.1 Sol contributed to project development and tooling.

## TLDR

### Cycle counts and latency at 1 MHz

Each cell shows **cycles / latency in milliseconds**. The lowest latency in each row is bold.

| Layer | NHWC | NCHW | Explicit im2col | im2collette FIFO |
|---|---:|---:|---:|---:|
| CIFAR10 tutorial conv1 | 96,353 / 96.353 | **74,722 / 74.722** | 136,337 / 136.337 | 96,325 / 96.325 |
| CIFAR10 tutorial conv2 | 83,913 / 83.913 | **79,174 / 79.174** | 94,473 / 94.473 | 83,893 / 83.893 |
| MNIST example conv1 | 121,714 / 121.714 | **86,913 / 86.913** | 171,634 / 171.634 | 121,610 / 121.610 |
| Historical MNISTConvNet tutorial conv2 | 113,697 / 113.697 | 115,194 / 115.194 | 120,545 / 120.545 | **113,681 / 113.681** |

Latency is measured in simulation from accepted start through the final output store. It includes planning, input and weight transfers, core execution, and output transfers; reset, test-tensor preload, and golden-reference calculation are excluded. At 1 MHz, latency in milliseconds equals cycles divided by 1,000. See the [full cycle and phase data](reports/cycle_results.csv).

### FPGA resources and timing

| Implementation | LUTs | Flip-flops | BRAM tiles | DSPs | WNS at 50 MHz (ns) | Estimated Fmax (MHz) |
|---|---:|---:|---:|---:|---:|---:|
| NHWC | 18,765 | 9,900 | 15 | 111 | -1.584 | 46.33 |
| Centralized NCHW | 60,966 | 17,995 | 15 | 206 | -11.345 | 31.90 |
| Explicit im2col | 21,540 | 11,412 | 175 | 171 | -2.397 | 44.65 |
| im2collette FIFO | 30,640 | 14,423 | 20 | 111 | -9.409 | 34.00 |

WNS is worst negative slack against the 20 ns synthesis constraint. Estimated Fmax is derived from that slack; placement and routing were not performed. NHWC uses the fewest LUTs and flip-flops and has the highest estimated Fmax. Centralized NCHW uses more LUTs and DSPs, while explicit im2col uses the most BRAM.

### Workload power at 1 MHz

| Implementation | Dynamic power (mW) | Static power (mW) | Total power (mW) |
|---|---:|---:|---:|
| NHWC | 1 | 123 | 124 |
| Centralized NCHW | 1 | 123 | 123–124 |
| Explicit im2col | 5 | 130 | 135 |
| im2collette FIFO | 1 | 123 | 124 |

The centralized total is 124 mW for CIFAR10 conv1 and 123 mW for the other three layers. Components and totals are rounded independently to 1 mW, so displayed components may not sum exactly to the total. These workload estimates are separate from the vectorless power reports. Matched-net activity coverage is 89% for NHWC, 85% for centralized NCHW, 84% for explicit im2col, and 72% for FIFO. External backing-memory power is excluded.

### Estimated energy per layer at 1 MHz

| Layer | NHWC (mJ) | Centralized NCHW (mJ) | Explicit im2col (mJ) | im2collette FIFO (mJ) |
|---|---:|---:|---:|---:|
| CIFAR10 tutorial conv1 | 11.948 | **9.266** | 18.405 | 11.944 |
| CIFAR10 tutorial conv2 | 10.405 | **9.738** | 12.754 | 10.403 |
| MNIST example conv1 | 15.093 | **10.690** | 23.171 | 15.080 |
| Historical MNISTConvNet tutorial conv2 | 14.098 | 14.169 | 16.274 | **14.096** |

Energy is the reported total power multiplied by layer latency. At 1 MHz, each cycle takes 1 microsecond. The lowest estimated energy for each layer is bold; small differences should be interpreted with the power rounding and annotation limits above.
