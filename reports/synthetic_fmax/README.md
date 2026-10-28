# Synthetic layers at individual estimated maximum frequencies

Each architecture runs at its own estimated maximum frequency: **NHWC 46.331 MHz**, **NCHW 31.903 MHz**, **explicit im2col 44.649 MHz**, and **im2collette FIFO 34.003 MHz**. These are post-synthesis estimates from the existing 50 MHz WNS, using period = 20 ns − WNS; placement and routing were not performed.

The same four layers, original synthetic tensors, and unchanged synthesized hardware are used. All 16 native XSim activity/power cases passed output, interface, cycle/accounting, SAIF-duration, and frequency-specific timing checks. The original 16 RTL acceptances are reused with matching hardware and tensor hashes. No resynthesis was performed.

## Latency per layer (ms)

| Layer | NHWC | NCHW | Explicit im2col | im2collette FIFO |
| --- | ---: | ---: | ---: | ---: |
| CIFAR10 tutorial conv1 | **2.080** | 2.342 | 3.054 | 2.833 |
| CIFAR10 tutorial conv2 | **1.811** | 2.482 | 2.116 | 2.467 |
| MNIST example conv1 | **2.627** | 2.724 | 3.844 | 3.576 |
| Historical MNISTConvNet tutorial conv2 | **2.454** | 3.611 | 2.700 | 3.343 |

## Workload power and energy per layer

| Architecture | Layer | Cycles | Dynamic (mW) | Static (mW) | Total (mW) | Total energy (mJ) | Timing met |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| [NHWC](channel_first/cifar10_conv1/power.rpt) | CIFAR10 tutorial conv1 | 96,353 | 41 | 123 | 164 | 0.341068 | [Yes](channel_first/cifar10_conv1/timing_fmax.rpt) |
| [NHWC](channel_first/cifar10_conv2/power.rpt) | CIFAR10 tutorial conv2 | 83,913 | 38 | 123 | 161 | 0.291600 | [Yes](channel_first/cifar10_conv2/timing_fmax.rpt) |
| [NHWC](channel_first/mnist_conv1/power.rpt) | MNIST example conv1 | 121,714 | 41 | 123 | 164 | 0.430840 | [Yes](channel_first/mnist_conv1/timing_fmax.rpt) |
| [NHWC](channel_first/mnist_legacy_conv2/power.rpt) | Historical MNISTConvNet tutorial conv2 | 113,697 | 36 | 123 | 159 | 0.390192 | [Yes](channel_first/mnist_legacy_conv2/timing_fmax.rpt) |
| [NCHW](centralized/cifar10_conv1/power.rpt) | CIFAR10 tutorial conv1 | 74,722 | 24 | 123 | 147 | 0.344298 | [Yes](centralized/cifar10_conv1/timing_fmax.rpt) |
| [NCHW](centralized/cifar10_conv2/power.rpt) | CIFAR10 tutorial conv2 | 79,174 | 21 | 123 | 144 | 0.357366 | [Yes](centralized/cifar10_conv2/timing_fmax.rpt) |
| [NCHW](centralized/mnist_conv1/power.rpt) | MNIST example conv1 | 86,913 | 21 | 123 | 143 | 0.389573 | [Yes](centralized/mnist_conv1/timing_fmax.rpt) |
| [NCHW](centralized/mnist_legacy_conv2/power.rpt) | Historical MNISTConvNet tutorial conv2 | 115,194 | 20 | 123 | 143 | 0.516338 | [Yes](centralized/mnist_legacy_conv2/timing_fmax.rpt) |
| [Explicit im2col](explicit/cifar10_conv1/power.rpt) | CIFAR10 tutorial conv1 | 136,337 | 239 | 131 | 370 | 1.129810 | [Yes](explicit/cifar10_conv1/timing_fmax.rpt) |
| [Explicit im2col](explicit/cifar10_conv2/power.rpt) | CIFAR10 tutorial conv2 | 94,473 | 237 | 131 | 368 | 0.778656 | [Yes](explicit/cifar10_conv2/timing_fmax.rpt) |
| [Explicit im2col](explicit/mnist_conv1/power.rpt) | MNIST example conv1 | 171,634 | 235 | 131 | 366 | 1.406936 | [Yes](explicit/mnist_conv1/timing_fmax.rpt) |
| [Explicit im2col](explicit/mnist_legacy_conv2/power.rpt) | Historical MNISTConvNet tutorial conv2 | 120,545 | 236 | 131 | 367 | 0.990844 | [Yes](explicit/mnist_legacy_conv2/timing_fmax.rpt) |
| [im2collette FIFO](im2collette_fifo/cifar10_conv1/power.rpt) | CIFAR10 tutorial conv1 | 96,325 | 29 | 123 | 152 | 0.430589 | [Yes](im2collette_fifo/cifar10_conv1/timing_fmax.rpt) |
| [im2collette FIFO](im2collette_fifo/cifar10_conv2/power.rpt) | CIFAR10 tutorial conv2 | 83,893 | 26 | 123 | 149 | 0.367614 | [Yes](im2collette_fifo/cifar10_conv2/timing_fmax.rpt) |
| [im2collette FIFO](im2collette_fifo/mnist_conv1/power.rpt) | MNIST example conv1 | 121,610 | 29 | 123 | 152 | 0.543617 | [Yes](im2collette_fifo/mnist_conv1/timing_fmax.rpt) |
| [im2collette FIFO](im2collette_fifo/mnist_legacy_conv2/power.rpt) | Historical MNISTConvNet tutorial conv2 | 113,681 | 24 | 123 | 147 | 0.491457 | [Yes](im2collette_fifo/mnist_legacy_conv2/timing_fmax.rpt) |

## Measurement and interpretation

Power components and totals are independently rounded to 1 mW. Matched-net annotation coverage is 89% for NHWC, 85% for NCHW, 84% for explicit im2col, and 72% for FIFO; Vivado reports High confidence. Native XSim uses zero-delay synthesized-netlist activity, which omits routed glitches. External backing-memory power is excluded. These are estimates, not measured board power or routed maximum frequencies.

Activity was captured natively using XSim `open_saif`, recursive `log_saif`, and `close_saif`, scoped to `/tb_conv_core/GATE`. The window runs from accepted start to the final output store/done; it excludes reset, test-tensor preload, and reference calculation. Raw SAIF duration equals accepted cycles × the exact period: NHWC 21.584 ns, NCHW 31.345 ns, explicit 22.397 ns, FIFO 29.409 ns. Odd picosecond periods use high/low phases differing by 1 ps to preserve the full period. Power analysis uses the same clock period on the matching synthesized checkpoint.

NHWC and explicit captures wait for the simulator’s global startup reset to end before the original testbench reset sequence; this wait is outside the measured job. Their initial startup failures were excluded. Accepted NCHW and FIFO results were preserved. No accelerator behavior or synthetic tensors changed.

The tests cover signed 8-bit synthetic convolution operands and wrapped 32-bit sums, without bias, activation, pooling, or external memory power. Each layer uses one deterministic tensor set; this is not a distribution-wide energy study.

[CSV](results.csv) and [JSON](results.json) include all 16 cases, dynamic/static/total energy, the 1 MHz baseline comparison, exact periods, geometry, tensor/netlist/checkpoint hashes, native SAIF and capture-script hashes, and relative paths to evidence. Raw power, annotation, frequency-specific timing, acceptance logs, and accounting records are retained byte-for-byte. Large raw SAIF files remain private; their hashes identify the accepted captures. [Frequencies](frequencies.json) preserve the WNS derivation. Original common-clock results remain in the [1 MHz report](../README.md).
