#!/usr/bin/env python3
"""Replays one frame of a seta2.cpp game as MAME draws it when the raster interrupt is in use (Guardians' rowscroll scenes):
MAME calls update_partial(vpos - 1) every time the raster timer fires with register 0x3c bit 0 set, drawing the lines since the
last update from the state of that moment, and draws the rest at the start of the vertical blank.

    seta2_replay.py <set> <statedir> <frame> [...] [--hw D]

  --hw D   instead, the core's way (rtl/s2_video.sv): each line drawn from the state at MAME's (line, 0), + D dots (of MAME's 512)
           while register 0x3c bit 0 is set

The state dir needs consecutive captures N-1 and N (f<N-1>.*, f<N>.*) and wlog.txt covering frame N-1 (tools/capture.py --wlog):
the writes between the two notifiers are replayed in order on the state at N-1, the raster timer is re-armed on every write to 0x3c
as vregs_w does (hpos 0 of line m_rasterposition, or the current hpos + 0x100 when that line is the current one), and the frame is
compared with MAME's pixels of frame N.  Prints the differing pixels with and without the partial updates.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import seta2_ref as R


def load_wlog(path):
    ev = []
    for line in open(path):
        p = line.split()
        if len(p) != 6:
            continue
        ev.append((int(p[0]), int(p[1]), int(p[2]), int(p[3], 16), int(p[4], 16), int(p[5], 16)))
    return ev


def replay(setname, sdir, n, ev, gfx, hw=None):
    a = R.load_state(sdir, n - 1)
    b = R.load_state(sdir, n)
    spr, pal, vr = list(a['spr']), list(a['pal']), list(a['vr'])
    priv = R.private_list(a['lst']) if a['lst'] else [0] * 0x800
    w, h = b['w'], b['h']
    bitmap = [[0] * w for _ in range(h)]
    last = -1                                         # the last line drawn
    timer = None                                      # absolute dot (v * 512 + h) when the raster timer fires
    updates = []

    def update_to(vpos):
        nonlocal last
        if hw is not None:
            return
        hi = min(vpos - 1, h - 1)
        if hi > last:
            R.render_lines(bitmap, vr, priv, spr, gfx, w, last + 1, hi)
            updates.append((last + 1, hi))
            last = hi

    events = [e for e in ev if e[0] == n - 1]
    hwnext = 0                                         # hw mode: the next line to draw

    def hw_lines_until(t):
        # the core draws line y once MAME's raster reaches (y, 0) [+ hw dots while 0x3c bit 0 is set] (rtl/s2_video.sv)
        nonlocal hwnext
        while hwnext < h:
            due = hwnext * 512 + (hw if (vr[0x3c // 2] & 1) else 0)
            if due > t:
                break
            R.render_lines(bitmap, vr, priv, spr, gfx, w, hwnext, hwnext)
            hwnext += 1

    for (f, v, hp, off, data, mask) in events:
        t = v * 512 + hp
        if v >= 256 - 24:                              # (writes in the vblank before line 0 come first)
            t -= 256 * 512
        if hw is not None:
            hw_lines_until(t - 1)
        # the timer fires before this write if it is due
        if timer is not None and timer <= t:
            tv = timer // 512
            if vr[0x3c // 2] & 1:
                update_to(tv)
            timer = None
        # the write
        if off < 0x40000:
            i = off >> 1
            spr[i] = (spr[i] & ~mask | data & mask) & 0xffff
        elif 0x40000 <= off < 0x50000:
            i = (off - 0x40000) >> 1
            pal[i] = (pal[i] & ~mask | data & mask) & 0xffff
        elif 0x60000 <= off < 0x60040:
            r = (off - 0x60000) >> 1
            vr[r] = (vr[r] & ~mask | data & mask) & 0xffff
            if r in (0x12, 0x13) and data:
                R.list_copy(spr, priv)
            if r == 0x1e:
                pos = vr[0x1f]
                if pos == v:
                    timer = t + 0x100
                elif pos * 512 > t:
                    timer = pos * 512
                else:
                    timer = None                      # next frame
    update_to(h)                                      # the rest at the start of vblank
    if hw is not None:
        hw_lines_until(1 << 30)
    ref = R.picture(bitmap, b['pal1'])
    mame = b['rgb']
    diff = sum(1 for i in range(0, len(ref), 3) if ref[i:i + 3] != mame[i:i + 3])
    whole = R.picture(R.render(b['vr'], R.private_list(b['lst']) if b['lst'] else [0] * 0x800, b['spr'], gfx, w, h), b['pal1'])
    diff0 = sum(1 for i in range(0, len(whole), 3) if whole[i:i + 3] != mame[i:i + 3])
    return diff, diff0, len(updates)


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    s, sdir = argv[1], argv[2]
    gfx = R.Gfx(open(os.path.join(paths.WORK, 'regions', s, 'video.bin'), 'rb').read())
    ev = load_wlog(os.path.join(sdir, 'wlog.txt'))
    bad = 0
    hw = None
    if '--hw' in argv:
        hw = int(argv[argv.index('--hw') + 1])
        argv = [a for a in argv if a not in ('--hw', str(hw))]
    for n in [int(x) for x in argv[3:]]:
        d, d0, u = replay(s, sdir, n, ev, gfx, hw)
        bad += d != 0
        if hw is None:
            print('frame %5d: %6d differing pixels with %d partial updates (%6d drawing the frame at once)' % (n, d, u, d0))
        else:
            print('frame %5d: %6d differing pixels drawing each line at its start + %d dots in raster mode (%6d at once)' % (n, d, hw, d0))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
