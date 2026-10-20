#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares (from the owner's ohmygod-mister/mister/tools/check_ram_depth.py).

    check_ram_depth.py <output_files/Seta2.fit.rpt> [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always (a two-dimensional unpacked array was once built half as deep,
invisible in every bench and broken on the board).  Run this on every fit report; it exits 1 if a listed memory is shallower than its
minimum, or is missing.
"""
import re
import sys

# (instance name fragment, minimum words, minimum width)
EXPECT = [
    # the video chip: sprite RAM (8 byte lanes of 32 K), palette (two byte halves of 32 K), the private sprite list
] + [("s2_video:u_video|s2_dpram:g_spr[%d].u_lane|altsyncram" % i, 32768, 8) for i in range(8)] + [
    ("s2_video:u_video|altsyncram:pal_hi", 32768, 8),
    ("s2_video:u_video|altsyncram:pal_lo", 32768, 8),
    ("s2_video:u_video|altsyncram:plist", 512, 61),
    # the line buffer: 8 banks of 128 x 15 (2 lines x 512 dots)
] + [("s2_render:u_render|s2_dpram:g_lb[%d].u_bank|altsyncram" % i, 128, 15) for i in range(8)] + [
    # the 68000 work RAM (64 KB in two byte halves) and the program cache
    ("s2_main:u_main|altsyncram:ram_hi", 32768, 8),
    ("s2_main:u_main|altsyncram:ram_lo", 32768, 8),
    ("s2_cache:u_cache|altsyncram:dat", 1024, 64),
    ("s2_cache:u_cache|altsyncram:tags", 256, 10),
]


def main():
    path = sys.argv[1]
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin, bmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING  %-52s (expected >= %d x %d)" % (frag, wmin, bmin))
            bad += 1
            continue
        for n, w, b in hits:
            # a wide RAM may be split into several blocks side by side; only depth matters here
            ok = w >= wmin
            if not ok:
                bad += 1
            print("%s  %-52s %6d x %-3d (>= %d)" % ("ok     " if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
