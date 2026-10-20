#!/usr/bin/env python3
"""MAME 0.289's X1-010 (src/devices/sound/x1_010.cpp, sound_stream_update) written out, driven by a write log of
tools/lua/x1log.lua; writes the mono mix (L + R, as seta2's speaker) at the chip's own rate (clock / 512), for comparing the RTL
(sim/snd +native) sample by sample.

    x1_model.py <x1.log> <x1snd.bin> <seconds> <out.wav> [--alt] [--chunk N] [--shift K]

  --alt      32.53047 MHz / 2 instead of 50 MHz / 3
  --chunk N  MAME's timing: x1_010_device::write does not update the stream first, so a write takes effect from the start of the
             sound update it falls in (N samples per update); default: from the sample at the write's time, as the hardware
  --shift K  every write K samples later
  --applied F  the sample each write takes effect from, one line per write (sim/snd +sync +alog=F): the RTL bench's timing
"""
import array
import sys
import wave

VOL_BASE = 2 * 32 * 256 // 30


def main(argv):
    if len(argv) < 5:
        print(__doc__)
        return 2
    log, romp, secs, outp = argv[1], argv[2], float(argv[3]), argv[4]
    clock = 32530470.0 / 2 if '--alt' in argv else 50e6 / 3
    rate = clock / 512
    chunk = int(argv[argv.index('--chunk') + 1]) if '--chunk' in argv else 0
    shift = int(argv[argv.index('--shift') + 1]) if '--shift' in argv else 0
    applied = [int(l) for l in open(argv[argv.index('--applied') + 1])] if '--applied' in argv else None
    rom = open(romp, 'rb').read()
    pages = len(rom) // 0x20000
    ev = []
    for line in open(log):
        p = line.replace(',', '.').split()
        if len(p) < 4:
            continue
        t = float(p[0])
        n = int(t * rate)                                   # the first sample at or after the write
        if t * rate > n:
            n += 1
        if chunk:
            n = n // chunk * chunk
        n += shift
        if applied is not None:
            n = applied[len(ev)] if len(ev) < len(applied) else 1 << 40
        if p[1] == 'x':
            ev.append((n, 'x', int(p[2], 16), int(p[3], 16), int(p[4], 16)))
        else:
            ev.append((n, 'b', int(p[2]), int(p[3], 16), 0))
    reg = bytearray(0x2000)
    bank = [0] * 8
    smp = [0] * 16
    env = [0] * 16
    nsamp = int(secs * rate)
    out = array.array('h', [0] * nsamp)
    ei = 0
    for n in range(nsamp):
        while ei < len(ev) and ev[ei][0] <= n:
            _, k, a, d, m = ev[ei]
            ei += 1
            if k == 'b':
                bank[a & 7] = d
                continue
            off = a & 0x1fff
            data = d & 0xff
            ch, r = off >> 3, off & 7
            if ch < 16 and r == 0 and (reg[off] & 1) == 0 and (data & 1):
                smp[ch] = 0
                env[ch] = 0
            reg[off] = data
        acc = 0
        for ch in range(16):
            b = ch * 8
            st = reg[b]
            if not st & 1:
                continue
            div = 1 if st & 0x80 else 0
            if not st & 2:                                  # PCM
                start = reg[b + 4] << 12
                end = (0x100 - reg[b + 5]) << 12
                vol = reg[b + 1]
                freq = reg[b + 2] >> div
                if freq == 0:
                    freq = 4
                delta = smp[ch] >> 4
                if start + delta >= end:
                    reg[b] = st & 0xfe
                    continue
                addr = (start + delta) & 0xfffff
                v = rom[(bank[addr >> 17] % pages) * 0x20000 + (addr & 0x1ffff)]
                v = v - 256 if v > 127 else v
                acc += v * ((vol >> 4) & 15) * VOL_BASE + v * (vol & 15) * VOL_BASE
                smp[ch] = (smp[ch] + freq) & 0xffffffff
            else:                                           # waveform
                start = (reg[b + 1] << 7) + 0x1000
                freq = ((reg[b + 3] << 8) + reg[b + 2]) >> div
                envb = reg[b + 5] << 7
                delta = env[ch] >> 10
                if (st & 4) and delta >= 0x80:
                    reg[b] = st & 0xfe
                    continue
                vol = reg[(envb + (delta & 0x7f)) & 0x1fff]
                v = reg[(start + ((smp[ch] >> 10) & 0x7f)) & 0x1fff]
                v = v - 256 if v > 127 else v
                acc += v * ((vol >> 4) & 15) * VOL_BASE + v * (vol & 15) * VOL_BASE
                smp[ch] = (smp[ch] + freq) & 0xffffffff
                env[ch] = (env[ch] + reg[b + 4]) & 0xffffffff
        s = acc >> 8
        out[n] = 32767 if s > 32767 else -32768 if s < -32768 else s
    w = wave.open(outp, 'wb')
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(int(rate + 0.5))
    w.writeframes(out.tobytes())
    w.close()
    print('%d samples, %d writes' % (nsamp, len(ev)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
