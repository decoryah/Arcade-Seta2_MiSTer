#!/usr/bin/env python3
"""The per-set configuration of the seta2 core: what the MRA tells the core about the board (memory map, clocks, CRTC timing, the
graphics ROM's size), used by make_mra.py and the benches.

CRTC values: the registers the games program (captured from MAME: tools/capture.py, f*.vr words 0..7); the visible size is MAME's.
Dot clocks: Guardians' is measured on its boards (15.23 kHz / 58.5 Hz, 15.19 kHz / 58.27 Hz); for the others it is chosen from the
crystals on their boards so that the totals give ~15.7 kHz / ~60 Hz (MAME runs all of them at 60 Hz).  See PLAN.md.

    seta2_cfg.py [set]     prints the table (or one set's derived timing)
"""
import sys

MCLK = 96_000_000                 # the core's machine clock

# memory maps (s2_main.sv decodes them by number)
MAP_GRDIANS, MAP_GUNDAMEX, MAP_MJ4SIMAI, MAP_MYANGEL, MAP_MYANGEL2, MAP_PZLBOWL, MAP_PENBROS = range(7)

CPU_50_3 = 50_000_000 / 3          # XTAL(50'000'000) / 3
CPU_32_2 = 32_530_470 / 2          # XTAL(32'530'470) / 2  (seta2_32m)

#        set          map           cpu       dot (Hz)          H regs 0,2,4,6            V regs 8,a,c,e          W    H
_T = {
    'grdians':   (MAP_GRDIANS,  CPU_50_3, 50_000_000 / 8,    (0x2e, 0x59, 0x188, 0x19a), (3, 0x14, 0xfe, 0x102), 304, 232),
    'grdiansa':  (MAP_GRDIANS,  CPU_32_2, 50_000_000 / 8,    (0x2e, 0x59, 0x188, 0x19a), (3, 0x14, 0xfe, 0x102), 304, 232),
    'grdiansbl': (MAP_GRDIANS,  CPU_32_2, 50_000_000 / 8,    (0x2e, 0x59, 0x188, 0x19a), (3, 0x14, 0xfe, 0x102), 304, 232),
    'gundamex':  (MAP_GUNDAMEX, CPU_32_2, 32_530_470 / 4,    (0x34, 0x70, 0x1f1, 0x206), (2, 0x17, 0xf7, 0x104), 384, 224),
    'mj4simai':  (MAP_MJ4SIMAI, CPU_50_3, 32_530_470 / 4,    (0x20, 0x65, 0x1e5, 0x204), (2, 0x0f, 0xff, 0x105), 384, 240),
    'myangel':   (MAP_MYANGEL,  CPU_50_3, 32_530_470 / 4,    (0x1e, 0x5d, 0x1d5, 0x200), (2, 0x0f, 0xfd, 0x105), 376, 240),
    'myangel2':  (MAP_MYANGEL2, CPU_50_3, 32_530_470 / 4,    (0x1e, 0x5d, 0x1d5, 0x200), (2, 0x0e, 0xfc, 0x105), 376, 240),
    'pzlbowl':   (MAP_PZLBOWL,  CPU_50_3, 32_530_470 / 4,    (0x20, 0x58, 0x1d8, 0x204), (1, 0x0f, 0xff, 0x105), 384, 240),
    'penbros':   (MAP_PENBROS,  CPU_50_3, 28_000_000 / 4,    (0x3f, 0x65, 0x1a5, 0x1c0), (3, 0x0f, 0xef, 0x0ff), 320, 224),
    'ablast':    (MAP_PENBROS,  CPU_50_3, 28_000_000 / 4,    (0x3f, 0x65, 0x1a5, 0x1c0), (3, 0x0f, 0xef, 0x0ff), 320, 224),
}
SETS = list(_T)

# The totals the core sends where they are not the CRTC's (dots per line, lines per frame).  The RetroTINK 4K sorts a MiSTer
# direct-video signal into a class by its lines per frame: the other sets' 261 / 262 lines are "MiSTer 240p", Guardians' 259 and
# Penguin Brothers' 256 were "MiSTer Gen.", a class in which it squashes the picture while the MiSTer OSD is open.  So 262 lines,
# and a line shortened to keep the frame rate: Guardians 409 x 262 = 58.33 Hz (the boards measure 58.27 and 58.5 Hz; the CRTC's
# 411 x 259 = 58.71 Hz), Penguin Brothers 445 x 262 = 60.04 Hz (the CRTC's 449 x 256 = 60.9 Hz; MAME 60 Hz).  The picture and
# the syncs keep the CRTC's positions; the added lines and the removed dots are blanking at the end of the frame / line.
RASTER = {
    'grdians': (409, 262), 'grdiansa': (409, 262), 'grdiansbl': (409, 262),
    'penbros': (445, 262), 'ablast': (445, 262),
}


def totals(s):
    """(dots per line, lines per frame) the core sends for set s"""
    mp, cpu, dot, hr, vr, w, h = _T[s]
    return RASTER.get(s, (hr[3] + 1, vr[3] + 1))


def video_cfg(s, video_region_size):
    """the video chip's configuration for set s: dict of the s2_video inputs"""
    mp, cpu, dot, hr, vr, w, h = _T[s]
    ht, vt = totals(s)
    elements = video_region_size // 64
    mask = 1
    while mask < elements:
        mask <<= 1
    return {
        'dot_inc': round(dot / MCLK * (1 << 24)),
        'h_total': ht, 'h_sync': hr[0], 'h_start': hr[1], 'h_width': w,
        'v_total': vt, 'v_sync': vr[0], 'v_start': vr[1], 'v_height': h,
        'tile_mask': (mask - 1) & 0x7ffff, 'tile_count': elements,
        'map': mp, 'cpu_hz': cpu, 'dot_hz': dot,
    }


def timing(s):
    mp, cpu, dot, hr, vr, w, h = _T[s]
    ht, vt = totals(s)
    return dot / ht, dot / ht / vt


if __name__ == '__main__':
    for s in (sys.argv[1:] or SETS):
        hz, vz = timing(s)
        print('%-10s %6.3f kHz  %6.3f Hz' % (s, hz / 1000, vz))
