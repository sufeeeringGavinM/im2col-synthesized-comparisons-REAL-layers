# Current accelerator results

The trained 784→128→10 MNIST model runs on the bias/scale/quantization-only NHWC and two-slot NCHW designs. Hidden ReLU is performed in software/testbench on actual outputs. Final biased INT32 scores bypass requantization.

The [opening README table](../../README.md) combines unquantized→quantized resources/Fmax changes and the current model's common 20 MHz/individual-Fmax latency, power and energy. Detailed numeric results are in [results.csv](results.csv); exact layer/state counters are in [cycles.json](cycles.json) and [phase_cycles.csv](phase_cycles.csv).

## Training and arithmetic

The included [Keras notebook](../../tools/mnist/MNIST_Training_Test_3_.ipynb) defines training and export: 12 epochs, batch size 128, Adam 0.001, 20% validation, final-epoch weights. Training uses seed 196 for reproducibility. Calibration uses the 48,000 training images, excluding the 12,000 validation images. [Metrics](../../tools/mnist/training/METRICS.json) report 97.53% float and 97.51% integer accuracy on 10,000 test images. An independent NumPy reference matches every final integer score from notebook inference. Notebook source-cell identity and original/published file hashes are retained in [training provenance](../../tools/mnist/training/PROVENANCE.json).

Both architectures pass 20 selected MNIST images and three directed stress cases (46 pipeline cases total), plus four four-state controls each. Every selected image checks 128 hidden outputs and ten final scores before/after software handoff. Both classify 18/20 correctly; the selected subset is not full-test-set RTL accuracy. Native synthesized-netlist runs check actual memory transfers against shadow RTL and all 138 outputs against the integer reference at 20 MHz and each architecture's own estimated Fmax. See [validation.json](validation.json), [RTL results](rtl_results.json), [20 MHz native results](native_20mhz.json) and [Fmax native results](native_fmax.json).

## Why the cycles differ

NHWC 264,976 versus NCHW 299,366 cycles gives NHWC 11.49% fewer cycles (NCHW 12.98% more). Both perform 1,040 jobs: 1,027 in 784→128 and 13 in 128→10. NCHW's 34,390 extra cycles are exactly 24,960 core startup + 9,360 outer input-address setup + 70 layer planning. These are measured partitions of the whole-layer phase counters; they are not additional work to add on top of the totals.

- Core startup: NHWC delivers its first activation pass after simpler counter initialization; NCHW initializes spatial divisions and bank/per-row address state, adding 24 cycles/job across 1,040 jobs. The first-job diagnostic has NHWC PRIME/LOAD/RUN = 5/10/21 versus NCHW = 1/10/49; both have 21 advancing cycles, while NCHW has 28 RUN wait cycles. The net busy difference is 24 cycles, because PRIME is four cycles shorter. Weight loading overlaps address preparation, so do not add it twice. The [core diagnostic](core_trace.json) deliberately stops after the first job.
- Outer input setup: NCHW spends nine cycles/job calculating its residue-swizzled spatial pitches and bank/address increments before local input placement; NHWC proceeds directly using its running counters. This is 9,360 ADDRESS_SETUP cycles versus zero.
- Layer planning: NCHW's banked-storage capacity planner needs seven sequential divisions plus intermediate calculations; NHWC needs three, giving 69 versus 34 JOB_SETUP cycles/layer and 70 extra cycles for two layers.

Both designs spend 203,264 cycles loading weights through the serialized two-phase interface: 76.71% of NHWC and 67.90% of NCHW time. The first dense layer contributes about 98.72% of each total. This network has no spatial extent to offset NCHW's more general spatial setup cost. It does not establish universal layout superiority.

## Timing and resource interpretation

Vivado 2026.1 post-synthesis OOC results target Nexys Video `xc7a200tsbg484-1`, A10, INT8 operands, ACC32/CFG32, local 8/external 32 addresses and 15 KiB base SRAM. Runtime-configurable accelerator RTL hashes exactly match the accepted synthesis inputs; model changes do not require a new synthesis. [Release manifest](release_manifest.json) pins sources, preset and configuration. [Source identity](source_identity.json) pins public runtime/model files.

The [raw-output comparison](QUANTIZED_VS_RAW.md) and [underlying data](quantized_vs_raw.json) include bias, scale multiplication, rounding/shift and saturation in quantization. Raw controls predate descriptor chaining and use two versus eight requested synthesis threads. Changes therefore include wrapper and mapping effects. No matched raw notebook cycle, accuracy or power measurement is claimed. NHWC output SRAM maps into 1,760 LUTRAMs while BRAM falls 15→10; capacity stays unchanged. Both designs add four DSPs.

NHWC's worst path is accumulator SRAM read register→mem_wdata[0], 24.757 ns and 45 logic levels. NCHW remains limited by tap_mode→scheduler DSP A[16], 33.761 ns and 68 levels. All twenty paths are in [worst_paths.csv](worst_paths.csv) and the implementation `worst_paths_10.rpt` files. The 50 MHz target is missed; 20 MHz WNS is +22.234/+12.433 ns. Fmax estimates are 36.015/26.619 MHz. Native Fmax clocks are 27.766/37.568 ns (36.015/26.618 MHz): 1 ps simulator precision rounds NCHW's requested 18.7835 ns half-cycle to 18.784 ns. Actual-clock reanalysis gives WNS 0.000/+0.001 ns. No place/route or board timing closure is implied.

## Power method and limits

Each clock uses fresh, unmodified native XSim open_saif/log_saif/close_saif activity from the synthesized DUT, followed by read_saif/report_power on the matching DCP. Netlist writes feed the actual next-layer input. A shadow RTL checks port/control/address consistency; references only check outputs. No accepted simulation, training or synthesis is repeated for packaging.

The energy window spans accelerator busy cycles plus two descriptor-gap cycles and a 100 ps primitive propagation offset. Accelerator latency in the opening table excludes those extra intervals. The native evidence contains full start/end windows and accepted duration hashes. Activity annotation is 87% NHWC and 79% NCHW, with tool confidence High. Incomplete annotation, initialization/reset warnings, synthesized-netlist timing and independently rounded 1 mW power values limit precision. Software nonlinear processing has zero assigned simulated time; its latency/energy and external-memory power are excluded. These are estimates, not measured physical power.

Per implementation, `20mhz/` and `fmax/` contain sanitized power/timing reports, accepted-capture metadata, exact raw/post values and native checks. [Publication provenance](publication_provenance.json) records original/published report hashes and sanitization. Full native SAIF files, compiled snapshots and DCPs remain outside Git, identified by hashes. [Packaging validation](packaging_validation.json) records public CLI and integrity checks separately.

AI assistance: Codex. Existing course/reference-model and RTL foundation attribution is retained.
