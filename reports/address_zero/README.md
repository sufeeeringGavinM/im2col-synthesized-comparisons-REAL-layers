# Address-zero validation

Both layouts start reading descriptors at word address 0 by default.
The CNN regression matched prior output hashes, phase counters and cycle counts.
Both layouts passed Vivado synthesis and XSim at 20 MHz and their respective
estimated Fmax. Reported utilization, timing, latency, power and energy matched
the [prior release](../layer_program/README.md). SAIF annotation percentages
remained 87% for NHWC and 85% for NCHW, with 32 fewer matched and total nets
in each layout. These are post-synthesis estimates.

[Measurement comparison](COMPARISON.json) · [Native results](NATIVE_RESULTS.json)
