#!/usr/bin/env python3
"""The machine bench's lag behind MAME, in frames: for every bench picture (sim/sys: <dir>/f.fNNNNN.ppm) the lags k for which MAME's
frame N - k is the same picture (MAME's captures of every frame: tools/capture.py <set> A-B/1), and the lags all of them allow.
The scripted inputs for the bench are MAME's moved by that lag (tools/gun_inputs.py --lag, tools/play_inputs.py --lag).

    sys_lag.py <bench dir> <MAME state dir> [kmin kmax]       (default -5 .. 20)

Pictures that do not pin the lag (a still screen: any k) are not listed; a bench picture no MAME frame matches is listed with "none".
"""
import glob
import os
import sys


def read_ppm(p):
    return open(p, 'rb').read().split(b'\n', 3)[3]


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    bdir, mdir = argv[1], argv[2]
    kmin, kmax = (int(argv[3]), int(argv[4])) if len(argv) > 4 else (-5, 20)
    ks = range(kmin, kmax + 1)
    cache = {}

    def mame(m):
        if m not in cache:
            p = os.path.join(mdir, 'f%05d.rgb' % m)
            cache[m] = open(p, 'rb').read() if os.path.exists(p) else None
        return cache[m]

    allowed = set(ks)
    for p in sorted(glob.glob(os.path.join(bdir, '*.f[0-9][0-9][0-9][0-9][0-9].ppm'))):
        fr = int(p[-9:-4])
        have = [k for k in ks if mame(fr - k) is not None]
        if len(have) < len(ks):
            continue                    # not every candidate captured: skip
        b = read_ppm(p)
        good = {k for k in ks if mame(fr - k) == b}
        if good != set(ks):
            print('bench frame %5d: lag %s' % (fr, ' '.join(str(k) for k in sorted(good)) if good else 'none'))
        if good:
            allowed &= good
    print('lags all pictures allow: %s' % (' '.join(str(k) for k in sorted(allowed)) or 'none'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
