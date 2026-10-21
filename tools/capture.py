#!/usr/bin/env python3
"""Runs MAME 0.289 headless on a seta2.cpp set and dumps frame states + MAME's pixels (tools/lua/dump_state.lua).

    capture.py <set> <frames> [outdir] [--play] [--seed N] [--log]

  <frames>   machine frames to capture, e.g. 300  or  150,300,600  or  150-3600/150 (first-last/step)
  outdir     default work/states/<set>
  --play     scripted inputs (coin at 200, start at 260, random joystick / buttons from 330); default: no inputs
  --log      also write ev.log (video register and TMP68301 register writes, with frame / line / dot)
  --wlog A-B also write wlog.txt: every write to the video chip in frames A..B (tools/seta2_replay.py)
  --nvram F  the light-gun games: start from this battery RAM file (else cleared)

Then: seta2_ref.py <set> <outdir>   compares the reference renderer with the pixels MAME drew.
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths

# set -> the CPU address of the video chip's sprite RAM (the driver's video_map, or penbros' own map: same offsets)
VBASE = {
    'grdians': 0xc00000, 'grdiansa': 0xc00000, 'grdiansbl': 0xc00000, 'gundamex': 0xc00000, 'mj4simai': 0xc00000,
    'myangel': 0xc00000, 'myangel2': 0xd00000, 'pzlbowl': 0x800000, 'penbros': 0xb00000, 'ablast': 0xb00000,
    'reelquak': 0xc00000, 'endrichs': 0xc00000, 'endrichsa': 0xc00000, 'endrichsb': 0xc00000, 'telpacfl': 0xb00000,
    'staraudi': 0xc00000, 'deerhunt': 0x800000, 'turkhunt': 0x800000, 'wschamp': 0x800000, 'trophyh': 0x800000,
}
# the clones: their parent's map
for _c, _p in (('deerhunta', 'deerhunt'), ('deerhuntb', 'deerhunt'), ('deerhuntc', 'deerhunt'), ('deerhuntd', 'deerhunt'),
               ('deerhunte', 'deerhunt'), ('deerhuntj', 'deerhunt'), ('wschampa', 'wschamp'), ('wschampb', 'wschamp'),
               ('trophyht', 'trophyh')):
    VBASE[_c] = VBASE[_p]


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    flags = [a for a in argv[1:] if a.startswith('--')]
    wl = None
    if '--wlog' in argv:
        wl = argv[argv.index('--wlog') + 1]
        argv = [a for a in argv if a not in ('--wlog', wl)]
        args = [a for a in argv[1:] if not a.startswith('--')]
    nvfile = None
    if '--nvram' in argv:
        nvfile = argv[argv.index('--nvram') + 1]
        argv = [a for a in argv if a not in ('--nvram', nvfile)]
        args = [a for a in argv[1:] if not a.startswith('--')]
    seed = None
    if '--seed' in argv:
        seed = argv[argv.index('--seed') + 1]
        args = [a for a in args if a != seed]
    if len(args) < 2 or args[0] not in VBASE:
        print(__doc__)
        return 2
    s, frames = args[0], args[1]
    out = os.path.abspath(args[2]) if len(args) > 2 else os.path.join(paths.WORK, 'states', s)
    os.makedirs(out, exist_ok=True)
    for sub in ('cfg', 'nvram'):
        os.makedirs(os.path.join(paths.WORK, sub), exist_ok=True)
    env = dict(os.environ, DUMPDIR=out, DUMPFRAMES=frames, VBASE='%06x' % VBASE[s],
               SCHEDULE='play' if '--play' in flags else 'none')
    if seed:
        env['SEED'] = seed
    if '--log' in flags:
        env['EVLOG'] = os.path.join(out, 'ev.log')
    if wl:
        env['WLOG'] = os.path.join(out, 'wlog.txt')
        env['WLOGFROM'], env['WLOGTO'] = wl.split('-')
    last = max(int(x) for part in frames.split(',') for x in
               ((part.split('-')[1].split('/')[0],) if '-' in part else (part,)))
    nvdir = os.path.join(paths.WORK, 'nvram')
    if VBASE[s] == 0x800000 and s != 'pzlbowl':
        # the light-gun games: a cleared battery RAM every run, as the core's without a saved file (MAME's file would carry the
        # last run's bookkeeping); its own folder, so that runs can go side by side
        nvdir = os.path.join(out, 'nvram')
        shutil.rmtree(nvdir, ignore_errors=True)
        if nvfile:
            os.makedirs(os.path.join(nvdir, s))
            shutil.copyfile(nvfile, os.path.join(nvdir, s, 'nvram'))
    cmd = [paths.MAME, s, '-rompath', paths.ROMS, '-cfg_directory', os.path.join(paths.WORK, 'cfg'),
           '-nvram_directory', nvdir, '-video', 'none', '-sound', 'none', '-nothrottle',
           '-skip_gameinfo', '-autoboot_script', os.path.join(paths.LUA, 'dump_state.lua'),
           '-seconds_to_run', str(last // 60 + 30)]
    r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    errs = [l for l in r.stdout.splitlines() if 'ERROR' in l or 'error' in l]
    for l in errs[:10]:
        print(l)
    n = sum(1 for f in os.listdir(out) if f.endswith('.rgb'))
    print('%s: %d states in %s (MAME exit %d)' % (s, n, out, r.returncode))
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
