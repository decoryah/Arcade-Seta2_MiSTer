#!/usr/bin/env python3
"""What the captured frames use of the X1-020 / DX-101: the features and the load the RTL has to carry.

    seta2_stats.py <set> [statedir]

Per set (over every captured frame): list entries and sub-sprites per frame, floating tilemaps (8x8 / 16x16), colour depth
modes, shadow, opaque, the "nozoom" bit 14, global size, flips, zoom / offset registers, the tile rows drawn per line
(drawgfx_line calls, from seta2_ref.render) and the range of tile codes (which 8 MB blocks of the graphics ROM).
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import seta2_ref as R


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    s = argv[1]
    sdir = argv[2] if len(argv) > 2 else os.path.join(paths.WORK, 'states', s)
    gfx = R.Gfx(open(os.path.join(paths.WORK, 'regions', s, 'video.bin'), 'rb').read())
    feat = collections.Counter()
    vregs = collections.Counter()
    max_entries = max_subs = max_rows = 0
    blocks = collections.Counter()
    for fr in R.frames_in(sdir):
        st = R.load_state(sdir, fr)
        if not st['lst']:
            continue
        priv = R.private_list(st['lst'])
        spr = st['spr']
        vr = st['vr']
        vregs[tuple('%04x' % vr[i] for i in (8, 9, 10, 11, 12, 13, 14, 15))] += 1
        nent = nsub = 0
        for e in range(0, 0x800, 4):
            num, xo, yo, sprite = priv[e:e + 4]
            nent += 1
            n = (num & 0xff) + 1
            if (sprite & 0x7fff) < 0x600:
                nsub += n
                feat['depth%d' % ((num >> 8) & 7)] += 1
                if num & 0x0800: feat['shadow'] += 1
                if num & 0x2000: feat['opaque'] += 1
                if num & 0x4000: feat['nozoom'] += 1
                if num & 0x1000: feat['globalsize'] += 1
                if sprite & 0x8000:
                    feat['tilemap'] += 1
                    for k in range(n):
                        w = spr[(sprite & 0x7fff) * 4 + 4 * k: (sprite & 0x7fff) * 4 + 4 * k + 4]
                        feat['tilemap16' if w[2] & 0x8000 else 'tilemap8'] += 1
                else:
                    for k in range(n):
                        w = spr[(sprite & 0x7fff) * 4 + 4 * k: (sprite & 0x7fff) * 4 + 4 * k + 4]
                        if w[2] & 0x10: feat['flipx'] += 1
                        if w[2] & 0x08: feat['flipy'] += 1
            if num & 0x8000:
                break
        max_entries = max(max_entries, nent)
        max_subs = max(max_subs, nsub)
        stt = R.Stats()
        R.render(vr, priv, spr, gfx, st['w'], st['h'], stt)
        max_rows = max(max_rows, stt.max_rows)
        for c in stt.codes:
            blocks[(c * 64) >> 23] += 1
        z = (vr[0x10 // 2], vr[0x12 // 2], vr[0x14 // 2], vr[0x16 // 2], vr[0x18 // 2], vr[0x1a // 2], vr[0x1c // 2],
             vr[0x1e // 2])
        feat['zoom ' + ' '.join('%04x' % v for v in z)] += 1
        if vr[0x30 // 2] & 1: feat['blank'] += 1
    print('%s: list entries <= %d, sub-sprites <= %d per frame, tile rows per line <= %d' % (s, max_entries, max_subs, max_rows))
    print('  tile codes by 8 MB block of the ROM:', dict(sorted(blocks.items())))
    print('  CRTC (8..f):', dict(vregs))
    for k, v in sorted(feat.items()):
        print('  %-48s %d' % (k, v))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
