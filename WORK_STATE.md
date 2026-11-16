# Accelerator status

The accelerator implements NHWC and two-slot NCHW with descriptor-based layer chaining, optional INT32 channel bias, scale multiplication and output quantization. Main source paths are `tiled/NHWC` and `tiled/NCHW`, with `conv_chain` as top.

Requantization bypass retains independently enabled bias. The MNIST testbench applies ReLU to actual hidden-layer output values between descriptors; final classification scores retain biased INT32 precision.

The MNIST demonstration uses the included Keras training notebook: 784→128→10, trained for 12 epochs and calibrated on 48,000 training images with seed 196. Float/integer accuracy is 97.53%/97.51% on 10,000 test images. Selected RTL cases, four-state controls and native synthesized-netlist inferences pass; resource/timing, 20 MHz and individual-Fmax power estimates are in [reports/current](reports/current/README.md). Supported commands are in [tools](tools/README.md).

Hardware source hashes match the accepted synthesis inputs. Source/model identity, export provenance and public CLI checks are retained with the reports. Historical studies retain their own source identities and measurements. Routed timing closure and board validation remain outside the reported evidence.
