#!/usr/bin/env python3
"""Package the finished Quartus builds as a release (from the owner's ohmygod-mister/mister/tools/release.py): copy each RBF to
releases/<name>_<YYYYMMDD>.rbf (seta2, seta2grd, seta2pen: one build per board dot clock) together with the fitter's and the timing
analyser's summaries (.fit.summary / .sta.summary) and the RAM depth report of tools/check_ram_depth.py (.ram_depths.txt), and print the
numbers.  MiSTer finds the core by the MRAs' <rbf> name plus the date in the file name, so keep both.

  py -3.8 tools/release.py [YYYYMMDD] [--builds DIR]        (default: today; DIR/<revision>/output_files)

Exit status 1 if any slack is negative or the RAM depth report has a problem.
"""
import datetime
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
OUT = os.path.join(PROJ, 'output_files')
REL = os.path.join(PROJ, 'releases')


def kv(path):
    d = {}
    for line in open(path, errors='replace'):
        if ' : ' in line:
            k, v = line.split(' : ', 1)
            d[k.strip()] = v.strip()
    return d


# the builds (Quartus revisions of Seta2.qpf) and their core file names (the MRAs' <rbf>, tools/make_mra.py)
BUILDS = [('Seta2', 'seta2'), ('Seta2Grd', 'seta2grd'), ('Seta2Pen', 'seta2pen')]


def release_one(out, rev, name, date):
    rbf = os.path.join(out, rev + '.rbf')
    if not os.path.exists(rbf):
        print('%s: no RBF in %s' % (rev, out))
        return 1
    stem = os.path.join(REL, '%s_%s' % (name, date))
    shutil.copyfile(rbf, stem + '.rbf')
    shutil.copyfile(os.path.join(out, rev + '.fit.summary'), stem + '.fit.summary')
    shutil.copyfile(os.path.join(out, rev + '.sta.summary'), stem + '.sta.summary')
    depth = subprocess.run([sys.executable, os.path.join(HERE, 'check_ram_depth.py'), os.path.join(out, rev + '.fit.rpt')],
                           stdout=subprocess.PIPE, universal_newlines=True)
    open(stem + '.ram_depths.txt', 'w').write(depth.stdout)
    fit = kv(stem + '.fit.summary')
    worst, cur = {}, None
    for line in open(stem + '.sta.summary', errors='replace'):
        m = re.match(r"Type\s*:\s*(\w[\w ]*?) '(.*)'", line)
        if m:
            cur = (m.group(1), m.group(2))
        m = re.match(r'Slack\s*:\s*(-?[\d.]+)', line)
        if m and cur:
            worst[cur] = float(m.group(1))
    neg = {k: v for k, v in worst.items() if v < 0}
    tight = sorted(worst.items(), key=lambda kv_: kv_[1])[:4]
    print('%s: %s (%d bytes)' % (rev, os.path.basename(stem + '.rbf'), os.path.getsize(stem + '.rbf')))
    print('  Quartus %s, fitter %s' % (fit.get('Quartus Prime Version', '?'), fit.get('Fitter Status', '?')))
    print('  Logic %s, RAM blocks %s, DSP %s, PLLs %s' % (fit.get('Logic utilization (in ALMs)', '?'), fit.get('Total RAM Blocks', '?'),
                                                           fit.get('Total DSP Blocks', '?'), fit.get('Total PLLs', '?')))
    print('  Timing: %d slack entries, %d negative; tightest: %s' % (len(worst), len(neg), '; '.join(
        '%s %s %.3f ns' % (t, c.split('|')[1] if '|' in c else c, s) for (t, c), s in tight)))
    print('  RAM depths: ' + (depth.stdout.strip().splitlines() or ['?'])[-1])
    return 1 if (neg or depth.returncode) else 0


def main(argv):
    """release.py [YYYYMMDD] [--builds DIR]: DIR/<revision>/output_files (separate project copies, compiled in parallel);
    default: this project's output_files for every revision built there"""
    builds = None
    if '--builds' in argv:
        builds = argv[argv.index('--builds') + 1]
        argv = [a for a in argv if a not in ('--builds', builds)]
    date = argv[0] if argv else datetime.date.today().strftime('%Y%m%d')
    os.makedirs(REL, exist_ok=True)
    bad = 0
    for rev, name in BUILDS:
        out = os.path.join(builds, rev, 'output_files') if builds else OUT
        bad += release_one(out, rev, name, date)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
