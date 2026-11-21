# Accelerator status

The accelerator implements NHWC and two-slot NCHW with descriptor-based layer chaining, optional INT32 channel bias, scale multiplication, output quantization and optional combinational ReLU. Main source paths are `tiled/NHWC` and `tiled/NCHW`, with `conv_chain` as top.

Requantization bypass retains independently enabled bias. The default Florida MNIST CNN uses hardware ReLU on completed hidden-layer writes and retains biased INT32 logits for software argmax. Four-state RTL replays and four native XSim captures passed. The measured sources and results are verified in the local checkout. [CNN measurements](reports/mnist_cnn_relu/README.md) · [Replay commands](tools/mnist/README.md)

The November 16 published dense model used testbench ReLU on actual hidden-layer outputs. It remains available for replay via `--model dense`, with the published measurements tied to the original quantization-only RTL. [Published dense evidence](reports/current/README.md)

The November 16 release manifest records its measured synthesis inputs. Commit `419ca20` updated comments in four RTL files. The November 16 runtime identity records those updated hashes. The current runner verifies the selected model and release sources and supports Python-only inference and automatic output directories. Historical studies retain their own source identities and measurements. Routed timing closure and board validation remain outside the reported evidence.
