#!/usr/bin/env python3
"""Compares the machine bench's pictures (sim/sys: <dir>/f.fNNNNN.ppm) with MAME's captures of the same set (tools/capture.py
states: f<N>.rgb), frame by frame: for every bench frame the MAME frame within +-window with the fewest differing pixels.

    sys_match.py <bench dir> <MAME state dir> [window] [--png outdir]

The bench and MAME start their frames at slightly different moments (MAME: 60 Hz, a 2.5 ms vblank; the core: the board's CRTC
timing), so a picture can pair with a neighbouring MAME frame; the captures are usually every 10 frames, the window 3.
"""
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio


def read_ppm(p):
    d = open(p, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = [int(x) for x in parts[1].split()]
    return w, h, parts[3]


def main(argv):
    png = None
    if '--png' in argv:
        png = argv[argv.index('--png') + 1]
        argv = [a for a in argv if a not in ('--png', png)]
    if len(argv) < 3:
        print(__doc__)
        return 2
    bdir, mdir = argv[1], argv[2]
    win = int(argv[3]) if len(argv) > 3 else 3
    total = exact = 0
    for p in sorted(glob.glob(os.path.join(bdir, '*.f[0-9][0-9][0-9][0-9][0-9].ppm'))):
        fr = int(p[-9:-4])
        w, h, rgb = read_ppm(p)
        nonblack = sum(1 for i in range(0, len(rgb), 3) if rgb[i:i + 3] != b'\x00\x00\x00')
        best = None
        for m in range(fr - win, fr + win + 1):
            q = os.path.join(mdir, 'f%05d.rgb' % m)
            if not os.path.exists(q):
                continue
            ref = open(q, 'rb').read()
            if len(ref) != len(rgb):
                continue
            n = sum(1 for i in range(0, len(rgb), 3) if rgb[i:i + 3] != ref[i:i + 3])
            if best is None or n < best[0]:
                best = (n, m, ref)
        if best is None:
            continue
        total += 1
        exact += best[0] == 0
        print('bench frame %5d: %6d non-black, best MAME frame %5d: %6d differing pixels' % (fr, nonblack, best[1], best[0]))
        if png and best[0]:
            os.makedirs(png, exist_ok=True)
            pngio.write(os.path.join(png, 'bench_%05d.png' % fr), w, h, rgb)
            pngio.write(os.path.join(png, 'mame_%05d.png' % best[1]), w, h, best[2])
    print('%d of %d bench frames identical to a MAME frame' % (exact, total))
    return 0 if exact == total else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
