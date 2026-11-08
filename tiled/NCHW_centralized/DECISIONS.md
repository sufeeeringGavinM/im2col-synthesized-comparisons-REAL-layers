# Sequential convolution chaining

Parent: the previous committed tiled implementation. The scheduler/core are unchanged; this version adds descriptor chaining and write-time quantization.
One shared combinational output quantizer; quantize only final outputs, preserving cycle scheduling. Runtime per-layer enable/shift/rounding controls are captured at accepted descriptor. Default testbench uses raw output, shift0, nearest rounding. Negative quantized outputs are sign-extended in the existing full word; low8 feed the next layer. No packed memory or extra buffers.

conv_chain adds descriptor_valid/ready/last and chain_busy/chain_done around the original per-layer busy/done. Producer owns descriptor storage and matching geometries/addresses. ready is low during computation and the completion cycle; valid may be held under backpressure. Producer must retain a descriptor until accepted. Last marks chain completion; there is no finite descriptor table or layer count limit. External-memory bounds/non-overlap and sequential shape compatibility are producer responsibilities. No reset between layers. No activation/bias/pooling.

One runtime-configurable synthesized conv_chain is compared to the official conv_accelerator top; controller and quantizer included, external memory/descriptor producer excluded in both. Post-synthesis estimates only.
