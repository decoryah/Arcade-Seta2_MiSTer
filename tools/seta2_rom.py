#!/usr/bin/env python3
"""Builds the ROM regions of the seta2.cpp sets from the MAME zips, exactly as the ROM_START blocks of
src/mame/seta/seta2.cpp (MAME 0.289) load them, and checks them against MAME's own regions (tools/lua/dump_regions.lua).

    seta2_rom.py check [set ...]      compare with work/regions/<set>/<region>.bin (the phase-1 sets by default)
    seta2_rom.py build <set> <dir>    write <region>.bin for the set
    seta2_rom.py list [set ...]       print the parsed load table

The table is read from the driver source itself (paths.MAME_SRC), not typed in: ROM_REGION / ROM_REGION16_BE, ROM_LOAD,
ROM_LOAD16_BYTE, ROM_LOAD16_WORD_SWAP, ROM_LOAD32_WORD, ROM_LOAD64_WORD and ROM_CONTINUE are the macros the driver uses.
Files are found in the merged zip by CRC (a clone's own files sit in a <clone>/ folder of the parent's zip).

Byte order: the regions are as MAME's Lua `region:read_u8` returns them, i.e. the 68000's view (byte 0 = the high byte of
word 0).  ROM_LOAD16_WORD_SWAP swaps the two bytes of every word of the file; `check` is the proof.
Regions the core does not use (the PLD dumps) are not compared.
"""
import os
import re
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths

PHASE1 = ['grdians', 'grdiansa', 'grdiansbl', 'gundamex', 'mj4simai', 'myangel', 'myangel2', 'pzlbowl', 'penbros', 'ablast']

_NUM = r'(0x[0-9a-fA-F]+|\d+)'


def _int(s):
    return int(s, 0)


def parse_source(path=None):
    """-> {set: {'parent': p or None, 'regions': [(tag, size, flags, [loads])]}}
    a load is (file, crc, mode, offset, length, [(offset, length) continues]); mode in n, b16, ws16, w32, w64"""
    src = open(path or paths.MAME_SRC, encoding='utf-8', errors='replace').read()
    sets = {}
    for m in re.finditer(r'^ROM_START\(\s*(\w+)\s*\)(.*?)^ROM_END', src, re.S | re.M):
        name, body = m.group(1), m.group(2)
        regions = []
        for line in body.split('\n'):
            line = line.split('//')[0].strip()
            if not line:
                continue
            r = re.match(r'ROM_REGION(16_BE)?\(\s*([0-9a-fA-Fx* ]+?)\s*,\s*"(\w+)"\s*,\s*([^)]*)\)', line)
            if r:
                size = 1
                for f in r.group(2).split('*'):
                    size *= _int(f.strip())
                regions.append((r.group(3), size, r.group(4).strip(), []))
                continue
            r = re.match(r'ROM_(LOAD|LOAD16_BYTE|LOAD16_WORD_SWAP|LOAD32_WORD|LOAD64_WORD)\(\s*"([^"]+)"\s*,\s*' + _NUM +
                         r'\s*,\s*' + _NUM + r'\s*,\s*(.*)\)\s*$', line)
            if r:
                mode = {'LOAD': 'n', 'LOAD16_BYTE': 'b16', 'LOAD16_WORD_SWAP': 'ws16', 'LOAD32_WORD': 'w32',
                        'LOAD64_WORD': 'w64'}[r.group(1)]
                crc = re.search(r'CRC\(([0-9a-fA-F]+)\)', r.group(5))
                nodump = 'NO_DUMP' in r.group(5)
                regions[-1][3].append((r.group(2), None if nodump else int(crc.group(1), 16), mode,
                                       _int(r.group(3)), _int(r.group(4)), []))
                continue
            r = re.match(r'ROM_CONTINUE\(\s*' + _NUM + r'\s*,\s*' + _NUM + r'\s*\)', line)
            if r:
                regions[-1][3][-1][5].append((_int(r.group(1)), _int(r.group(2))))
                continue
            raise ValueError('%s: unparsed ROM line: %s' % (name, line))
        sets[name] = {'parent': None, 'regions': regions}
    for m in re.finditer(r'^GAME\(\s*\d+\s*,\s*(\w+)\s*,\s*(\w+)\s*,', src, re.M):
        if m.group(1) in sets and m.group(2) != '0':
            sets[m.group(1)]['parent'] = m.group(2)
    return sets


def _place(buf, data, mode, ofs):
    """copies `data` into `buf` from region offset `ofs` with the macro's interleave"""
    if mode == 'n':
        buf[ofs:ofs + len(data)] = data
    elif mode == 'ws16':
        buf[ofs:ofs + len(data):2] = data[1::2]
        buf[ofs + 1:ofs + len(data):2] = data[0::2]
    elif mode == 'b16':
        buf[ofs:ofs + 2 * len(data):2] = data
    elif mode in ('w32', 'w64'):
        step = 4 if mode == 'w32' else 8
        n = len(data) // 2
        buf[ofs:ofs + step * n:step] = data[0::2]
        buf[ofs + 1:ofs + 1 + step * n:step] = data[1::2]
    else:
        raise ValueError(mode)


def _span(mode, length):
    """bytes of the region from the load's offset to its last byte, inclusive"""
    if mode in ('n', 'ws16'):
        return length
    if mode == 'b16':
        return 2 * length - 1
    step = 4 if mode == 'w32' else 8
    return step * (length // 2) - (step - 2)


class Zips:
    """file lookup by CRC in the set's merged zip (the parent's zip for a clone)"""
    def __init__(self, zipname):
        self.z = zipfile.ZipFile(os.path.join(paths.ROMS, zipname + '.zip'))
        self.by_crc = {}
        for i in self.z.infolist():
            self.by_crc.setdefault(i.CRC, i)

    def read(self, name, crc):
        i = self.by_crc.get(crc)
        if i is None:
            raise FileNotFoundError('%s (crc %08x) not in %s' % (name, crc, self.z.filename))
        return self.z.read(i)


def build(setname, table=None):
    """-> {region: bytearray}"""
    table = table or parse_source()
    d = table[setname]
    z = Zips(d['parent'] or setname)
    out = {}
    for tag, size, flags, loads in d['regions']:
        buf = bytearray(size)
        for fname, crc, mode, ofs, length, conts in loads:
            if crc is None:
                continue                                  # NO_DUMP (a PLD): MAME leaves it empty too
            data = z.read(fname, crc)
            pos = 0
            for o, n in [(ofs, length)] + conts:
                chunk = data[pos:pos + n]
                if len(chunk) != n:
                    raise ValueError('%s: %s shorter than its loads' % (setname, fname))
                if o + _span(mode, n) > size:
                    raise ValueError('%s: %s overruns region %s' % (setname, fname, tag))
                _place(buf, chunk, mode, o)
                pos += n
        out[tag] = buf
    return out


def check(sets):
    table = parse_source()
    bad = 0
    for s in sets:
        regs = build(s, table)
        rdir = os.path.join(paths.WORK, 'regions', s)
        for tag, buf in regs.items():
            if tag == 'plds':
                continue
            p = os.path.join(rdir, tag + '.bin')
            if not os.path.exists(p):
                print('%-10s %-8s no MAME dump (%s)' % (s, tag, p))
                bad += 1
                continue
            ref = open(p, 'rb').read()
            if ref == bytes(buf):
                print('%-10s %-8s %9d bytes  identical' % (s, tag, len(buf)))
            else:
                diff = next((i for i in range(min(len(ref), len(buf))) if ref[i] != buf[i]), None)
                print('%-10s %-8s DIFFERENT (mame %d, ours %d bytes, first difference at %s)' %
                      (s, tag, len(ref), len(buf), hex(diff) if diff is not None else 'end'))
                bad += 1
    return bad


def main(argv):
    if len(argv) >= 2 and argv[1] == 'check':
        return 1 if check(argv[2:] or PHASE1) else 0
    if len(argv) == 4 and argv[1] == 'build':
        os.makedirs(argv[3], exist_ok=True)
        for tag, buf in build(argv[2]).items():
            open(os.path.join(argv[3], tag + '.bin'), 'wb').write(buf)
        return 0
    if len(argv) >= 2 and argv[1] == 'list':
        t = parse_source()
        for s in argv[2:] or PHASE1:
            print(s, 'parent', t[s]['parent'])
            for tag, size, flags, loads in t[s]['regions']:
                print('  region %-8s %08x %s' % (tag, size, flags))
                for l in loads:
                    print('    %-24s %08x %-4s %08x %08x %s' % (l[0], l[1] or 0, l[2], l[3], l[4], l[5]))
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
