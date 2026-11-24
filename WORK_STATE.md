# Accelerator status

The official local NHWC and two-slot NCHW build uses `conv_program` to fetch
27-word descriptors from backing memory starting at word address 0. The
host pulses `start` once. Integrations that need a runtime descriptor base
can set `USE_PROGRAM_BASE_INPUT=1`. `conv_chain` serves streamed-descriptor
callers.

The Florida MNIST CNN uses hardware ReLU on completed hidden-layer writes
and retains biased INT32 logits for software argmax. The address-zero build
matched the published layer-program cycle counts, resource counts and
post-synthesis timing. Both layouts also reproduced the reported power and energy at both clocks.
[Address-zero validation](reports/address_zero/README.md).
[Published measurements](reports/layer_program/README.md) ·
[Replay commands](tools/mnist/README.md).

The original Dense model remains available via `--model dense`. Its
November 16 measurements use the quantization-only RTL and testbench ReLU.
[Historical Dense evidence](reports/current/README.md).
