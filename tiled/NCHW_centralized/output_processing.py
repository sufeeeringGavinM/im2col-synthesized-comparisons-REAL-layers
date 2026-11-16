"""Integer output reference for the accelerator. AI assistance: Codex."""


def wrap32(value):
    return (int(value) + (1 << 31)) % (1 << 32) - (1 << 31)


def requantize(value, multiplier=1, shift=0, nearest=True, enable=False, bias=0):
    """Bias wraps at ACC32; scaling uses a full signed64 product and wide rounding."""
    if not 0 <= multiplier <= 0xffffffff or not 0 <= shift <= 31:
        raise ValueError('Expected unsigned32 multiplier and shift 0..31')
    value = wrap32(wrap32(value) + bias)
    if not enable:
        return value
    product = value * multiplier
    if nearest and shift:
        magnitude = (abs(product) + (1 << (shift - 1))) >> shift
        scaled = -magnitude if product < 0 else magnitude
    else:
        scaled = product >> shift
    return max(-128, min(127, scaled))
