#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (from the owner's ohmygod-mister/mister/tools/package.py):

  _Arcade/<title>.mra                              the MRAs, with their _alternatives/ folders   (mra/**/*.mra)
  _Arcade/cores/seta2_<YYYYMMDD>.rbf               the three core files, one per board dot clock (releases/):
  _Arcade/cores/seta2grd_<YYYYMMDD>.rbf              seta2 (Gundam EX, Mahjong Yonshimai, My Angel 1 / 2, Puzzle De Bowling),
  _Arcade/cores/seta2pen_<YYYYMMDD>.rbf              seta2grd (Guardians), seta2pen (Penguin Brothers, A-Blast, the light-gun
                                                     games); the MRAs pick

  python tools/package.py [RELEASE] [--cores YYYYMMDD]

RELEASE names the zip (e.g. 20261021b); the core files are those of RELEASE's date, or of --cores (a release that changes only
the MRAs keeps the cores of an older one: `package.py 20261021b --cores 20261021`; they keep their own names and dates in the
zip); without arguments the newest date that all three RBFs in releases/ have.

Writes dist/Seta2_MiSTer_<RELEASE>.zip (dist/ is not in the repository: attach the zip to the GitHub release).  Unzip it over
the root of the SD card.  No ROMs are in it: the MAME 0.289 romsets (grdians.zip, gundamex.zip, mj4simai.zip, myangel.zip,
myangel2.zip, pzlbowl.zip, penbros.zip, deerhunt.zip, turkhunt.zip, wschamp.zip, trophyh.zip, and the clones' zips with a split
set) go to /media/fat/games/mame/.
"""
import glob
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')


def main(argv):
    cores = None
    if '--cores' in argv:
        cores = argv[argv.index('--cores') + 1]
        argv = [a for a in argv if a not in ('--cores', cores)]
    release = argv[0] if argv else None
    names = ('seta2', 'seta2grd', 'seta2pen')
    dates = None
    for n in names:
        found = {re.search(r'_(\d{8}[a-z]?)\.rbf$', r).group(1)
                 for r in glob.glob(os.path.join(REPO, 'releases', '%s_*.rbf' % n)) if re.search(r'%s_\d{8}[a-z]?\.rbf$' % n, r)}
        dates = found if dates is None else dates & found
    want = cores or release
    if want:
        dates = {d for d in dates if d == want}
    if not dates:
        print('no date %swith all of releases/seta2_, seta2grd_, seta2pen_YYYYMMDD.rbf (--cores for an older one)' % (want + ' ' if want else ''))
        return 1
    date = sorted(dates)[-1]
    release = release or date
    rbfs = [os.path.join(REPO, 'releases', '%s_%s.rbf' % (n, date)) for n in names]
    mra_root = os.path.join(REPO, 'mra')
    mras = sorted(glob.glob(os.path.join(mra_root, '**', '*.mra'), recursive=True),
                  key=lambda p: (os.path.dirname(p).lower(), os.path.basename(p).lower()))
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'Seta2_MiSTer_%s.zip' % release)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in mras:
            z.write(full, '_Arcade/' + os.path.relpath(full, mra_root).replace(os.sep, '/'))
        for rbf in rbfs:
            z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print('%s: %d MRAs + %s' % (out, len(mras), ', '.join(os.path.basename(r) for r in rbfs)))
    with zipfile.ZipFile(out) as z:
        for i in z.infolist():
            print('  %9d  %s' % (i.file_size, i.filename))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
