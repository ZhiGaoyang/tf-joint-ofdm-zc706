"""Fixed 128/32 OFDM conventions; not an FFT IP bit-accurate model."""

import numbers

import numpy as np


NFFT = 128
NCP = 32
NDATA = 88
TX_GAIN = 0.5
PILOT_SIGNED = np.array([-43, -31, -19, -7, 7, 19, 31, 43])
PILOT_VALUES = np.array([1, 1, 1, -1, -1, 1, -1, 1], dtype=complex)
ACTIVE_SIGNED = np.r_[np.arange(-48, 0), np.arange(1, 49)]


def checked_int(value, minimum, maximum, name):
    if isinstance(value, (bool, np.bool_)) or not isinstance(value, numbers.Integral) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer in [{minimum}, {maximum}]")
    return int(value)


def carrier_bins():
    data = np.array([k for k in ACTIVE_SIGNED if k not in PILOT_SIGNED]) % NFFT
    pilots = PILOT_SIGNED % NFFT
    nulls = np.array([k for k in range(NFFT) if k not in ACTIVE_SIGNED % NFFT])
    return data, pilots, nulls


def bits_per_symbol(modulation):
    if modulation not in ("QPSK", "16QAM"):
        raise ValueError("modulation must be QPSK or 16QAM")
    return 2 if modulation == "QPSK" else 4


def checked_bits(bits):
    bits = np.asarray(bits)
    if bits.ndim != 1 or not np.all((bits == 0) | (bits == 1)):
        raise ValueError("bits must be a one-dimensional binary array")
    return bits.astype(np.uint8)


def bytes_to_bits(data):
    return np.unpackbits(np.frombuffer(data, dtype=np.uint8), bitorder="big")


def bits_to_bytes(bits):
    bits = checked_bits(bits)
    if len(bits) % 8:
        raise ValueError("byte conversion requires a multiple of 8 bits")
    return np.packbits(bits, bitorder="big").tobytes()


def map_bits(bits, modulation):
    bits = checked_bits(bits)
    bps = bits_per_symbol(modulation)
    if len(bits) % bps:
        raise ValueError("incomplete constellation symbol")
    groups = bits.reshape(-1, bps).astype(int)
    if modulation == "QPSK":
        return ((1 - 2*groups[:, 0]) + 1j*(1 - 2*groups[:, 1])) / np.sqrt(2)
    levels = np.array([3, 1, -3, -1])
    return (levels[2*groups[:, 0]+groups[:, 1]] + 1j*levels[2*groups[:, 2]+groups[:, 3]]) / np.sqrt(10)


def demap_symbols(symbols, modulation):
    bps = bits_per_symbol(modulation)
    symbols = np.asarray(symbols, dtype=complex)
    if symbols.ndim != 1 or not np.all(np.isfinite(symbols)):
        raise ValueError("symbols must be a finite one-dimensional array")
    labels = np.array([[int(x) for x in f"{v:0{bps}b}"] for v in range(2**bps)], dtype=np.uint8)
    reference = map_bits(labels.reshape(-1), modulation)
    # Ties select the smallest binary label, matching np.argmin order.
    indexes = np.argmin(abs(symbols[:, None] - reference[None, :])**2, axis=1)
    return labels[indexes].reshape(-1)


def checked_grid(grid):
    grid = np.asarray(grid, dtype=complex)
    if grid.ndim != 2 or grid.shape[1] != NFFT or not len(grid) or not np.all(np.isfinite(grid)):
        raise ValueError("grid must have shape (positive symbol count, 128) and finite values")
    return grid


def bits_to_grid(bits, modulation):
    bits = checked_bits(bits)
    capacity = NDATA * bits_per_symbol(modulation)
    if not len(bits) or len(bits) % capacity:
        raise ValueError("grid input must contain complete OFDM symbols")
    data, pilots, _ = carrier_bins()
    grid = np.zeros((len(bits)//capacity, NFFT), dtype=complex)
    grid[:, data] = map_bits(bits, modulation).reshape(-1, NDATA)
    grid[:, pilots] = PILOT_VALUES
    return grid


def grid_to_bits(grid, modulation):
    data, _, _ = carrier_bins()
    return demap_symbols(checked_grid(grid)[:, data].reshape(-1), modulation)


def grid_to_samples(grid):
    body = np.fft.ifft(checked_grid(grid), axis=1) * TX_GAIN
    return np.concatenate((body[:, -NCP:], body), axis=1).reshape(-1)


def samples_to_grid(samples):
    samples = np.asarray(samples, dtype=complex)
    if samples.ndim != 1 or not len(samples) or len(samples) % (NFFT+NCP) or not np.all(np.isfinite(samples)):
        raise ValueError("samples must contain complete, finite 160-sample OFDM symbols")
    body = samples.reshape(-1, NFFT+NCP)[:, NCP:]
    return np.fft.fft(body, axis=1) / TX_GAIN


def quantize_iq(values, width=16, fractional_bits=15):
    width = checked_int(width, 2, 32, "width")
    fractional_bits = checked_int(fractional_bits, 0, width-1, "fractional_bits")
    values = np.asarray(values, dtype=complex)
    if not np.all(np.isfinite(values)):
        raise ValueError("quantizer requires finite samples")
    low, high = -(2**(width-1)), 2**(width-1)-1
    components = np.stack((values.real, values.imag), axis=-1)
    # Clip in real units first to avoid overflow for large finite inputs.
    scaled = np.rint(np.clip(components, (low-1)/2**fractional_bits, (high+1)/2**fractional_bits) * 2**fractional_bits)
    clips = int(np.count_nonzero((scaled < low) | (scaled > high)))
    return np.clip(scaled, low, high).astype(np.int64), clips


def dequantize_iq(iq, fractional_bits=15):
    fractional_bits = checked_int(fractional_bits, 0, 31, "fractional_bits")
    iq = np.asarray(iq)
    if iq.ndim < 1 or iq.shape[-1] != 2 or not np.all(np.isfinite(iq)):
        raise ValueError("IQ array must end in a finite I,Q pair")
    return (iq[..., 0] + 1j*iq[..., 1]) / 2**fractional_bits


def pack_iq_words(iq):
    iq = np.asarray(iq)
    if iq.ndim < 1 or iq.shape[-1] != 2 or not np.issubdtype(iq.dtype, np.integer) or np.any(iq < -32768) or np.any(iq > 32767):
        raise ValueError("packing requires signed 16-bit integer I,Q pairs")
    values = iq.astype(np.int64) & 0xFFFF
    return (values[..., 0] | (values[..., 1] << 16)).astype(np.uint32)
