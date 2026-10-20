#!/usr/bin/env python3
"""Compares a bench's sound with MAME's (both mono 16-bit WAVs at the same rate):

    cmp_audio.py <rtl.wav> <mame.wav> [--from S] [--to S]

  rtl.wav    sim/snd (the X1-010 replayed with MAME's writes) or sim/sys +wav: the core's mono mix
  mame.wav   MAME -wavwrite -samplerate 48000 (seta2: the X1-010's two outputs into the mono speaker at 1.0)

Finds the lag (RMS envelopes, then sample cross-correlation near it), then the least-squares gain g of mame = g * rtl over the
aligned samples, the correlation and the residual.  g = 1 and a correlation near 1 mean the core's level and waveform are MAME's
(MAME resamples the chip's clock / 512 rate to 48 kHz with its own filter, so the samples are not identical).
"""
import array
import math
import sys
import wave


def load(path):
    with wave.open(path, 'rb') as w:
        assert w.getsampwidth() == 2, '16-bit WAV expected'
        rate, ch = w.getframerate(), w.getnchannels()
        a = array.array('h')
        a.frombytes(w.readframes(w.getnframes()))
    return rate, a[0::ch]


def envelope(x, win):
    return [math.sqrt(sum(v * v for v in x[i:i + win]) / win) for i in range(0, len(x) - win + 1, win)]


def corr(a, b):
    n = min(len(a), len(b))
    if n < 2:
        return 0.0
    ma, mb = sum(a[:n]) / n, sum(b[:n]) / n
    sab = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
    saa = sum((a[i] - ma) ** 2 for i in range(n))
    sbb = sum((b[i] - mb) ** 2 for i in range(n))
    return sab / math.sqrt(saa * sbb) if saa > 0 and sbb > 0 else 0.0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    t0 = float(argv[argv.index('--from') + 1]) if '--from' in argv else 0.0
    t1 = float(argv[argv.index('--to') + 1]) if '--to' in argv else None
    r1, x = load(argv[1])
    r2, m = load(argv[2])
    assert r1 == r2, (r1, r2)
    rate = r1
    a, b = int(t0 * rate), int(t1 * rate) if t1 else min(len(x), len(m))
    x, m = x[a:b], m[a:b]
    win = rate // 100
    ex, em = envelope(x, win), envelope(m, win)
    best = (-2, 0)
    for lag in range(-50, 51):                       # +-0.5 s in envelope steps
        if lag >= 0:
            c = corr(ex[lag:], em)
        else:
            c = corr(ex, em[-lag:])
        best = max(best, (c, lag))
    lag = best[1] * win
    # refine at sample resolution around the envelope lag
    seg = min(len(x), len(m)) - abs(lag) - 2 * win
    def at(l):
        if l >= 0:
            return corr(x[l:l + seg:3], m[0:seg:3])
        return corr(x[0:seg:3], m[-l:-l + seg:3])
    fine = max((at(l), l) for l in range(lag - win, lag + win + 1, 4))
    l = fine[1]
    fine = max((at(k), k) for k in range(l - 4, l + 5))
    l = fine[1]
    xs = x[l:] if l >= 0 else x
    ms = m if l >= 0 else m[-l:]
    n = min(len(xs), len(ms))
    sxx = sum(xs[i] * xs[i] for i in range(n))
    sxm = sum(xs[i] * ms[i] for i in range(n))
    g = sxm / sxx if sxx else 0.0
    res = math.sqrt(sum((ms[i] - g * xs[i]) ** 2 for i in range(n)) / n) if n else 0.0
    rms_m = math.sqrt(sum(v * v for v in ms[:n]) / n) if n else 0.0
    print('envelope correlation %.4f at lag %+d samples; sample correlation %.4f; gain mame/rtl %.4f; '
          'residual %.1f of MAME rms %.1f' % (best[0], l, fine[0], g, res, rms_m))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
