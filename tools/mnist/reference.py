"""Model-independent INT8/ACC32 convolution and dense reference. AI assistance: Codex."""
import numpy as np


def round_away(x):
    return np.sign(x) * np.floor(np.abs(x) + 0.5)


def preprocess(pixels):
    # Exact rational round-to-nearest for uint8 pixels; no half ties occur.
    return ((pixels.astype(np.int64) * 127 + 127) // 255).astype(np.int64)


def wrap32(x):
    return (x + (1 << 31)) % (1 << 32) - (1 << 31)


def layer(x, weight, bias, multiplier=1, shift=0, quantize=False, relu=False):
    """No PyTorch/model dependency; weights are [output,input]."""
    x = np.asarray(x, dtype=np.int64)
    weight = np.asarray(weight, dtype=np.int64)
    bias = np.asarray(bias, dtype=np.int64)
    assert x.min() >= -128 and x.max() <= 127
    assert weight.min() >= -128 and weight.max() <= 127
    # Bound every prefix partial sum, not just the completed signed sum.
    prefix_bound = np.abs(x) @ np.abs(weight).T
    output, stats = finish(x @ weight.T, bias, multiplier, shift, quantize, relu)
    stats.update(max_abs_prefix_bound=int(prefix_bound.max()),
                 accumulation_overflow_possible=int((prefix_bound > 2147483647).sum()))
    return output, stats


def conv_layer(x, weight, bias, stride, multiplier, shift, quantize, relu):
    """Valid convolution on NCHW inputs and KCRS weights, summed one tap at a time."""
    x = np.asarray(x, dtype=np.int64)
    weight = np.asarray(weight, dtype=np.int64)
    n, channels, h, w = x.shape
    k, in_channels, r, s = weight.shape
    if channels != in_channels:
        raise ValueError(f"Input has {channels} channels, weights require {in_channels}")
    si, sj = stride
    p, q = (h - r) // si + 1, (w - s) // sj + 1
    sums = np.zeros((n, p, q, k), dtype=np.int64)
    for i in range(r):
        for j in range(s):
            pixels = x[:, :, i:i + p * si:si, j:j + q * sj:sj].transpose(0, 2, 3, 1)
            sums += pixels @ weight[:, :, i, j].T
    output, stats = finish(sums, bias, multiplier, shift, quantize, relu)
    return output.transpose(0, 3, 1, 2), stats


def finish(sums, bias, multiplier, shift, quantize, relu):
    with_bias = wrap32(sums) + bias
    biased = wrap32(with_bias)
    stats = dict(bias_wraps=int((with_bias != biased).sum()),
                 biased_min=int(biased.min()), biased_max=int(biased.max()))
    if quantize:
        assert 0 <= multiplier <= 0xffffffff and 0 <= shift <= 31
        product = biased * multiplier
        if shift:
            magnitude = (np.abs(product) + (1 << (shift - 1))) >> shift
            rounded = np.where(product < 0, -magnitude, magnitude)
        else:
            rounded = product
        stats.update(saturated_low=int((rounded < -128).sum()),
                     saturated_high=int((rounded > 127).sum()),
                     values=int(rounded.size))
        output = np.clip(rounded, -128, 127)
    else:
        output = biased
        stats.update(saturated_low=0, saturated_high=0, values=int(biased.size))
    stats['relu_clamps'] = int((output < 0).sum()) if relu else 0
    if relu:
        output = np.maximum(output, 0)
    return output, stats


def infer(x, tensors, config):
    outputs, statistics = [], []
    for i, c in enumerate(config):
        x, s = layer(x, tensors[f'w{i}'], tensors[f'b{i}'],
                     c['multiplier'], c['shift'], c['quantize'], c['relu'])
        outputs.append(x)
        statistics.append(s)
    return outputs, statistics
