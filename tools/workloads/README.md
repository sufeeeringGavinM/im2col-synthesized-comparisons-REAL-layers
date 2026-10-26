# Complete small-model layer fixtures

Four full N1 convolution geometries from the official PyTorch CIFAR10 tutorial CNN and current MNIST example conv1 and historical MNISTConvNet tutorial conv2. Definitions and pinned primary source identities are in [layers.json](layers.json) and [model_geometries.json](model_geometries.json). Allstride1,padding0,dilation1,groups1. Synthetic signed8 inputs/weights and32bit wrapped sums; no bias/activation/pooling/accuracy claim. Every output is included. Identical fixtures across all architectures.

Python3 is sufficient. Regenerate with `python3 tools/workloads/generate.py --out-dir runs/generated-tensors`. The retained Python integer golden and independent full Verilog golden check results. [manifest.json](manifest.json) records exact checked fixture hashes. Convolution cycles and nativeSAIF are separate validations; post-synthesis power is not board measurement.
