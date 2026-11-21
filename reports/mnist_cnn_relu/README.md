# Florida MNIST CNN results

CNN with combinational writeback ReLU on the 10×10 NHWC and two-slot NCHW accelerators. The selected epoch-17 checkpoint achieved 98.65% float and 98.62% INT8 accuracy on 10,000 images. Both layouts matched all 2,106 values per image in three four-state RTL replays. The host ReLU controls matched hardware ReLU outputs and cycle counts.

- [Notebook](../../tools/mnist/MNIST_Training_Test_3_CNN.ipynb) and [training metrics](../../tools/mnist/training_cnn/METRICS.json)
- [Full-test-set integer check](integer_validation.json), [RTL validation](rtl_results.json) and [layer phases](phase_cycles.csv)
- [Utilization and timing values](hardware.json) and [native capture measurements](native_results.json)
- [NHWC synthesis paths](NHWC/worst_paths_10.rpt) and [source and capture identity](NHWC/source_and_capture_identity.json)
- [NCHW synthesis paths](NCHW/worst_paths_10.rpt) and [source and capture identity](NCHW/source_and_capture_identity.json)

Vivado 2026.1 post-synthesis estimates use Nexys Video xc7a200tsbg484-1 and 2 ns input and output delays. Both builds were synthesized at a 20 ns target period and meet timing at 20 MHz. One matching native XSim netlist inference per layout and clock feeds SAIF power analysis. NHWC annotated 87% of design nets and NCHW 85%. Activity stops at final write completion and includes six descriptor-gap cycles and a 100 ps simulator propagation offset. Energy uses this window. External-memory and software energy are outside the measurement. Vivado rounds dynamic, static and total power independently.

The [quantization-only dense release](../current/README.md) retains its own source files and measurement provenance.
