#!/usr/bin/env python3
"""Prepares the frozen-state bench of the video chip (sim/video): for every captured frame of a set, the private display list as
MAME's register 0x26 copy left it (f<N>.plst, 512 x 64-bit little-endian, from f<N>.lst), and the set's video configuration
(<statedir>/bench.cfg, key=value lines for tb_video.cpp).

    vbench_prep.py <set> [statedir]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import seta2_cfg
import seta2_ref as R


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    s = argv[1]
    sdir = argv[2] if len(argv) > 2 else os.path.join(paths.WORK, 'states', s)
    vbin = os.path.join(paths.WORK, 'regions', s, 'video.bin')
    cfg = seta2_cfg.video_cfg(s, os.path.getsize(vbin))
    with open(os.path.join(sdir, 'bench.cfg'), 'w') as f:
        for k in ('dot_inc', 'h_total', 'h_sync', 'h_start', 'h_width', 'v_total', 'v_sync', 'v_start', 'v_height',
                  'tile_mask', 'tile_count'):
            f.write('%s=%d\n' % (k, cfg[k]))
        f.write('video=%s\n' % vbin)
    n = 0
    for fr in R.frames_in(sdir):
        pre = os.path.join(sdir, 'f%05d' % fr)
        lst = R.words_le(open(pre + '.lst', 'rb').read()) if os.path.exists(pre + '.lst') else None
        priv = R.private_list(lst) if lst else [0] * 0x800
        open(pre + '.plst', 'wb').write(struct.pack('<2048H', *priv))
        n += 1
    print('%s: bench.cfg and %d private lists in %s' % (s, n, sdir))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
