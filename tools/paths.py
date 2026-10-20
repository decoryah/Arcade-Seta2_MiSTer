#!/usr/bin/env python3
"""Where things are, for every tool in this folder (same scheme as the owner's other cores).

  REPO      the repository (this core: the Quartus project, rtl/, sim/, mra/, tools/ ...).
  WORK      scratch area for MAME's dumps and snapshots, the ROM images, the bench's pictures (never committed):
            $SETA2_WORK, else work/ next to the repository.
  MAME      the oracle, MAME 0.289's executable: $SETA2_MAME, else "mame" (on the PATH).
  ROMS      the MAME 0.289 ROM folder (merged sets): $SETA2_ROMS, else roms/ next to the repository.
  MAME_SRC  MAME 0.289's src/mame/seta/seta2.cpp (the ROM loader and make_mra.py read it):
            $SETA2_MAME_SRC, else ref/mame/src/mame/seta/seta2.cpp next to the repository.

A local tools/paths_local.json (not in the repository) can set any of "mame", "roms", "mame_src", "work" for a machine.

  python tools/paths.py repo|work|mame|roms|mame_src
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TOP = os.path.dirname(REPO)                       # the folder the repository sits in, with work/ and ref/ beside it

_local = {}
try:
    with open(os.path.join(HERE, 'paths_local.json'), encoding='utf-8') as f:
        _local = json.load(f)
except (OSError, ValueError):
    pass


def _get(env, key, default):
    return os.environ.get(env) or _local.get(key) or default


WORK = os.path.abspath(_get('SETA2_WORK', 'work', os.path.join(TOP, 'work')))
MAME = _get('SETA2_MAME', 'mame', 'mame')
ROMS = _get('SETA2_ROMS', 'roms', os.path.join(TOP, 'roms'))
MAME_SRC = _get('SETA2_MAME_SRC', 'mame_src', os.path.join(TOP, 'ref', 'mame', 'src', 'mame', 'seta', 'seta2.cpp'))
LUA = os.path.join(HERE, 'lua')

if __name__ == '__main__':
    what = {'repo': REPO, 'work': WORK, 'mame': MAME, 'roms': ROMS, 'mame_src': MAME_SRC}
    if len(sys.argv) != 2 or sys.argv[1] not in what:
        print(__doc__)
        sys.exit(2)
    print(what[sys.argv[1]])
