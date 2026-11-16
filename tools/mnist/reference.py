"""Model-independent INT8/ACC32 dense reference. AI assistance: Codex."""
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
    sums = x @ weight.T
    biased = wrap32(wrap32(sums) + bias)
    stats = dict(max_abs_prefix_bound=int(prefix_bound.max()),
                 accumulation_overflow_possible=int((prefix_bound > 2147483647).sum()),
                 bias_wraps=int(((wrap32(sums) + bias) != biased).sum()),
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
