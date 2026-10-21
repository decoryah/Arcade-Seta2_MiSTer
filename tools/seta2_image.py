#!/usr/bin/env python3
"""The seta2 core's ROM image: what the MRA assembles and the core loads (rtl/s2_mem.sv), built here from MAME's regions
(tools/seta2_rom.py) for the benches and as the reference the MRAs are checked against (tools/mra_build.py).

    seta2_image.py <set> [out]      writes work/images/<set>.img (default)
    seta2_image.py all              every phase-1 set

Layout (byte offsets):
  0x0000000  header (4 KB): configuration bytes 0x00..0x3F (below), the 93C46 image (MAME's "eeprom" region) at 0x100..0x17F
  0x0100000  program: MAME's "maincpu" region in the 68000's byte order; gundamex's 0x500000-0x57FFFF at +0x200000
  0x0500000  X1-010 samples: MAME's "x1snd"
  0x0900000  graphics: MAME's "video" region as it is (its whole size: zeros where the region is erased)
The image ends with the graphics.

Header bytes (little-endian 16-bit values):
  0 'S'  1 '2'  2 memory map  3 flags: bit 0 CPU / X1-010 at 32.53047 MHz / 2, bit 1 93C46 on the parallel port, bit 2 myangel
  inputs, bit 3 mahjong inputs, bit 4 pzlbowl SYSTEM port, bit 5 gundamex SYSTEM / IN0 / IN1, bit 6 no button 3
  4..6 dot clock increment (24 bits)   8 h_total  10 h_sync  12 h_start  14 h_width  16 v_total  18 v_sync  20 v_start  22 v_height
  24..26 tile_mask  28..30 tile_count  32 sample pages - 1 (x1snd size / 128 KB - 1)  33 the light guns (seta2_cfg.GUNS)
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import seta2_cfg
import seta2_rom

IMG_PROG, IMG_SND, IMG_VID = 0x100000, 0x500000, 0x900000


def header(s, regions):
    vc = seta2_cfg.video_cfg(s, len(regions['video']))
    flags = 0
    if vc['cpu_hz'] == seta2_cfg.CPU_32_2:
        flags |= 1
    if 'eeprom' in regions:
        flags |= 2
    if vc['map'] in (seta2_cfg.MAP_MYANGEL, seta2_cfg.MAP_MYANGEL2):
        flags |= 4
    if vc['map'] == seta2_cfg.MAP_MJ4SIMAI:
        flags |= 8
    if vc['map'] == seta2_cfg.MAP_PZLBOWL:
        flags |= 16
    if vc['map'] == seta2_cfg.MAP_GUNDAMEX:
        flags |= 32
    if vc['map'] == seta2_cfg.MAP_PENBROS:
        flags |= 64
    h = bytearray(0x1000)
    h[0:4] = bytes([ord('S'), ord('2'), vc['map'], flags])
    h[4:7] = struct.pack('<I', vc['dot_inc'])[:3]
    h[8:24] = struct.pack('<8H', vc['h_total'], vc['h_sync'], vc['h_start'], vc['h_width'],
                          vc['v_total'], vc['v_sync'], vc['v_start'], vc['v_height'])
    h[24:28] = struct.pack('<I', vc['tile_mask'])
    h[28:32] = struct.pack('<I', vc['tile_count'])
    h[32] = len(regions['x1snd']) // 0x20000 - 1
    h[33] = seta2_cfg.GUNS.get(s, 0)
    if 'eeprom' in regions:
        e = regions['eeprom']
        h[0x100:0x100 + len(e)] = e
    return h


def build(s):
    regions = seta2_rom.build(s)
    prog = regions['maincpu']
    img = bytearray(IMG_VID + len(regions['video']))
    img[0:0x1000] = header(s, regions)
    img[IMG_PROG:IMG_PROG + min(len(prog), 0x200000)] = prog[:0x200000]
    if len(prog) > 0x500000:                                  # gundamex: 0x500000-0x57FFFF
        img[IMG_PROG + 0x200000:IMG_PROG + 0x280000] = prog[0x500000:0x580000]
    snd = regions['x1snd']
    img[IMG_SND:IMG_SND + len(snd)] = snd
    img[IMG_VID:] = regions['video']
    return img


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    sets = seta2_rom.PHASE1 if argv[1] == 'all' else [argv[1]]
    for s in sets:
        out = argv[2] if len(argv) > 2 and argv[1] != 'all' else os.path.join(paths.WORK, 'images', s + '.img')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        img = build(s)
        open(out, 'wb').write(img)
        print('%s: %d bytes -> %s' % (s, len(img), out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
