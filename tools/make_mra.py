#!/usr/bin/env python3
"""Writes the core's .mra files (one per MAME set) from the ROM_START tables of MAME's seta2.cpp (tools/seta2_rom.py), the
image layout (tools/seta2_image.py) and the DSW definitions of the driver's INPUT_PORTS, and checks each one: the image
tools/mra_build.py assembles from the .mra and the merged romset must be byte-identical to seta2_image.py's.

    make_mra.py [outdir]          default mra/

How the regions become MRA parts (Main_MiSTer support/arcade/mra_loader.cpp):
  - an <interleave output="N"> starts every output lane at the same offset and writes each part's bytes to the lanes its map
    names (digits read right to left: the rightmost is the word's first byte; digit d = the part's d-th byte); the image grows by
    the part that fills the first lane.  The buffer is not cleared, so every lane of every word gets a part: a lane MAME leaves
    empty (gundamex, mj4simai, penbros: three graphics ROMs per 64-bit row) gets a literal zero part.
  - zeros outside the ROMs (erased regions, padding) are literal parts with repeat, 64 bytes per repeat.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import seta2_rom
import seta2_cfg
import seta2_image as IMG

GAMES = {
    # set: (title, year, manufacturer, INPUT_PORTS name, file name, folder)
    'grdians':   ('Guardians / Denjin Makai II (P-FG01-1 PCB)', 1995, 'Winkysoft (Banpresto license)', 'grdians', 'Guardians', ''),
    'grdiansa':  ('Guardians / Denjin Makai II (P0-113A PCB)', 1995, 'Winkysoft (Banpresto license)', 'grdians',
                  'Guardians (P0-113A PCB)', '_alternatives/_Guardians'),
    'grdiansbl': ('Guardians / Denjin Makai II (bootleg)', 1998, 'bootleg (Intac Japan)', 'grdians', 'Guardians (bootleg)',
                  '_alternatives/_Guardians'),
    'gundamex':  ('Mobile Suit Gundam EX Revue', 1994, 'Banpresto', 'gundamex', 'Mobile Suit Gundam EX Revue', ''),
    'mj4simai':  ('Wakakusamonogatari Mahjong Yonshimai (Japan)', 1996, 'Maboroshi Ware', 'mj4simai',
                  'Wakakusamonogatari Mahjong Yonshimai', ''),
    'myangel':   ('Kosodate Quiz My Angel (Japan)', 1996, 'MOSS / Namco', 'myangel', 'Kosodate Quiz My Angel', ''),
    'myangel2':  ('Kosodate Quiz My Angel 2 (Japan)', 1997, 'MOSS / Namco', 'myangel2', 'Kosodate Quiz My Angel 2', ''),
    'pzlbowl':   ('Puzzle De Bowling (Japan)', 1999, 'Nihon System / MOSS', 'pzlbowl', 'Puzzle De Bowling', ''),
    'penbros':   ('Penguin Brothers (Japan)', 2000, 'Subsino', 'penbros', 'Penguin Brothers', ''),
    'ablast':    ('Hong Tian Lei (A-Blast) (Japan)', 2000, 'Subsino', 'penbros', 'Hong Tian Lei (A-Blast)', '_alternatives/_Penguin Brothers'),
}

# the core's joystick bits 4..10 (Seta2.sv): button 1..4, start, coin, service; "-" = the set has no such button
# The buttons' names, in MAME's order (Button 1 .. 4), as the games call them: Gundam EX's How To Play ("Button "A" is soft attack",
# "B" "middium", "C" hard, "D" "Throw"); Puzzle De Bowling's How To Play (left button: left-curve ball; centre: straight ball, the
# throw; right: the curve marking to the right) with Buttons 1 / 3 checked in MAME to be the left / right one; Penguin Brothers in
# MAME: Button 1 throws a bomb, Button 2 jumps (A-Blast is a hack of it); Guardians: attack, jump, special attack (the power gauge);
# My Angel 1 / 2: the quiz's answers 1 .. 4 (checked in MAME: Button 4 marks answer 4).  Mahjong Yonshimai: the keyboard's mahjong
# keys only.  Start and Coin follow; the service coin is the keyboard's 9 and the test mode the Service Mode DIP switch.
BUTTONS = {
    'grdians':  ['Attack', 'Jump', 'Special', '-'],
    'gundamex': ['Soft Attack', 'Medium Attack', 'Hard Attack', 'Throw'],
    'mj4simai': ['-', '-', '-', '-'],
    'myangel':  ['Answer 1', 'Answer 2', 'Answer 3', 'Answer 4'],
    'pzlbowl':  ['Left Curve', 'Throw', 'Right Curve', '-'],
    'penbros':  ['Bomb', 'Jump', '-', '-'],
}
BUTTONS['grdiansa'] = BUTTONS['grdiansbl'] = BUTTONS['grdians']
BUTTONS['myangel2'] = BUTTONS['myangel']
BUTTONS['ablast'] = BUTTONS['penbros']

_TABLE = None


def table():
    global _TABLE
    if _TABLE is None:
        _TABLE = seta2_rom.parse_source()
    return _TABLE


# ---------------------------------------------------------------- the parts of a region
def region_chunks(setname, tag):
    """-> (size, width, chunks): the region as words of `width` bytes; a chunk = (lane, first byte in the word, bytes per word,
    first word, words, file, crc, file offset, swapped)"""
    for rtag, size, flags, loads in table()[setname]['regions']:
        if rtag != tag:
            continue
        modes = {l[2] for l in loads if l[1] is not None}
        width = 8 if 'w64' in modes else 4 if 'w32' in modes else 2 if (modes & {'b16', 'ws16'}) else 1
        chunks = []
        for fname, crc, mode, ofs, length, conts in loads:
            if crc is None:
                continue
            fpos = 0
            for o, n in [(ofs, length)] + conts:
                if mode == 'n':
                    if width == 1:
                        chunks.append((0, 0, 1, o, n, fname, crc, fpos, False))
                    else:
                        # a plain load into a region of wider words: whole words
                        assert o % width == 0 and n % width == 0
                        chunks.append((0, 0, width, o // width, n // width, fname, crc, fpos, False))
                elif mode == 'ws16':
                    chunks.append((0, 0, 2, o // 2, n // 2, fname, crc, fpos, True))
                elif mode == 'b16':
                    chunks.append((o & 1, o & 1, 1, o // 2, n, fname, crc, fpos, False))
                else:
                    step = 4 if mode == 'w32' else 8
                    chunks.append(((o % step) // 2, o % step, 2, o // step, n // 2, fname, crc, fpos, False))
                fpos += n
        return size, width, chunks
    raise KeyError(tag)


def zeros(n):
    if n <= 0:
        return []
    if n % 64 == 0:
        return ['        <part repeat="0x%x">%s</part>' % (n // 64, ' '.join(['00'] * 64))]
    return ['        <part repeat="0x%x">00</part>' % n]


def region_parts(setname, tag, start, length, _width=None):
    """XML lines for region bytes [start, start + length): one interleave (or plain part) per stretch of words whose lanes come
    from the same files; empty stretches as zeros"""
    size, width, chunks = region_chunks(setname, tag)
    w0, w1 = start // width, (start + length) // width
    # word boundaries where some lane's source changes
    cuts = {w0, w1}
    for c in chunks:
        for x in (c[3], c[3] + c[4]):
            if w0 < x < w1:
                cuts.add(x)
    cuts = sorted(cuts)
    lines = []
    for a, b in zip(cuts, cuts[1:]):
        present = []
        for c in chunks:
            if c[3] <= a and b <= c[3] + c[4]:
                present.append(c)
        if not present:
            lines += zeros((b - a) * width)
            continue
        words = b - a
        if width == 1:
            c = present[0]
            lines.append('        <part name="%s" crc="%08x" offset="0x%x" length="0x%x"/>' % (c[5], c[6], c[7] + (a - c[3]), words))
            continue
        lines.append('        <interleave output="%d">' % (8 * width))
        # the word's bytes: the present chunks' lanes, the rest zeros (the loader does not clear its buffer)
        covered = [None] * width
        for c in present:
            for k in range(c[2]):
                covered[c[1] + k] = c
        lanes = []
        bpos = 0
        while bpos < width:
            c = covered[bpos]
            if c is not None:
                lanes.append((c[1], c[2], c))
                bpos = c[1] + c[2]
            else:
                e = bpos
                while e < width and covered[e] is None:
                    e += 1
                lanes.append((bpos, e - bpos, None))
                bpos = e
        for first, n, c in lanes:
            m = ['0'] * width
            for k in range(n):
                m[width - 1 - (first + k)] = str((n - k) if (c is not None and c[8]) else (k + 1))
            mp = ''.join(m)
            if c is not None:
                lines.append('            <part name="%s" crc="%08x" offset="0x%x" length="0x%x" map="%s"/>' % (
                    c[5], c[6], c[7] + (a - c[3]) * n, words * n, mp))
            else:
                lines.append('            <part repeat="0x%x" map="%s">%s</part>' % (words, mp, ' '.join(['00'] * n)))
        lines.append('        </interleave>')
    return lines


def rom_lines(setname):
    regs = {t: s for t, s, f, l in table()[setname]['regions']}
    img = IMG.build(setname)
    lines = []
    # header: the configuration bytes, then the EEPROM image (gundamex) at 0x100
    lines.append('        <!-- header: configuration (tools/seta2_image.py) -->')
    lines.append('        <part>%s</part>' % ' '.join('%02X' % b for b in img[0:0x40]))
    lines += zeros(0xc0)
    if 'eeprom' in regs:
        lines.append('        <!-- the 93C46 image -->')
        lines += region_parts(setname, 'eeprom', 0, regs['eeprom'])
        lines += zeros(0x100000 - 0x100 - regs['eeprom'])
    else:
        lines += zeros(0x100000 - 0x100)
    # program
    lines.append('        <!-- maincpu: the TMP68301 program (68000 byte order) -->')
    plen = min(regs['maincpu'], 0x200000)
    lines += region_parts(setname, 'maincpu', 0, plen)
    if regs['maincpu'] > 0x500000:
        lines += zeros(0x200000 - plen)
        lines.append('        <!-- maincpu 0x500000-0x57FFFF -->')
        lines += region_parts(setname, 'maincpu', 0x500000, 0x80000)
        lines += zeros(0x400000 - 0x280000)
    else:
        lines += zeros(0x400000 - plen)
    # samples
    lines.append('        <!-- x1snd: the X1-010 samples -->')
    lines += region_parts(setname, 'x1snd', 0, regs['x1snd'])
    lines += zeros(0x400000 - regs['x1snd'])
    # graphics
    lines.append('        <!-- video: the graphics ROM, 8 bytes per row of a tile (MAME\'s region as it is) -->')
    lines += region_parts(setname, 'video', 0, regs['video'])
    return lines


# ---------------------------------------------------------------- DIP switches from the driver's INPUT_PORTS
def def_str(s):
    s = s.strip()
    m = re.match(r'DEF_STR\(\s*(\w+)\s*\)', s)
    if m:
        v = m.group(1)
        if re.match(r'^\d+C_\d+C$', v):
            return v.replace('_', '/')
        return v.replace('_', ' ')
    m = re.match(r'"(.*)"$', s)
    return m.group(1) if m else s


def port_dips(ports_name, port):
    src = open(paths.MAME_SRC, encoding='utf-8').read()
    blk = re.search(r'INPUT_PORTS_START\(\s*%s\s*\)(.*?)INPUT_PORTS_END' % ports_name, src, re.S).group(1)
    i = blk.index('PORT_START("%s")' % port)
    j = blk.find('PORT_START(', i + 5)
    dsw = blk[i:j if j > 0 else len(blk)]
    dips = []                     # [mask, default, name, {value: label}]
    for line in dsw.splitlines():
        line = line.split('//')[0].strip()
        m = re.match(r'PORT_DIPNAME\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*(PORT_DIPLOCATION.*)?$', line)
        if m:
            dips.append([int(m.group(1), 16), int(m.group(2), 16), def_str(m.group(3)), {}])
            continue
        m = re.match(r'PORT_DIPSETTING\(\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)$', line)
        if m:
            dips[-1][3][int(m.group(1), 16)] = def_str(m.group(2))
            continue
        m = re.match(r'PORT_(DIPUNUSED|DIPUNKNOWN)_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*"(.*?)"\s*\)', line)
        if m:
            mask, dflt = int(m.group(2), 16), int(m.group(3), 16)
            dips.append([mask, dflt, '%s (%s)' % ('Unused' if m.group(1) == 'DIPUNUSED' else 'Unknown', m.group(4)), {mask: 'Off', 0: 'On'}])
            continue
        m = re.match(r'PORT_SERVICE_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,\s*IP_ACTIVE_LOW\s*,\s*"(.*?)"\s*\)', line)
        if m:
            mask = int(m.group(1), 16)
            dips.append([mask, mask, 'Service Mode', {mask: 'Off', 0: 'On'}])
            continue
    return dips


def switches_lines(setname, ports_name):
    dips = [(mask, d, n, s) for mask, d, n, s in port_dips(ports_name, 'DSW1')] + \
           [(mask << 8, d << 8, n, {v << 8: t for v, t in s.items()}) for mask, d, n, s in port_dips(ports_name, 'DSW2')]
    if setname == 'gundamex':
        # the Language jumper pad (MAME: SYSTEM bit 5) as bit 16 (byte 2 bit 0)
        dips.append((1 << 16, 1 << 16, 'Language (jumper)', {1 << 16: 'English', 0: 'Japanese'}))
    default = 0xFFFFFF
    lines = []
    for mask, dflt, name, settings in dips:
        mask &= 0xffffff
        bits = [b for b in range(24) if mask >> b & 1]
        default = (default & ~mask) | dflt
        ids = []
        for v in range(1 << len(bits)):
            val = sum(((v >> i) & 1) << b for i, b in enumerate(bits))
            ids.append(settings.get(val, 'Unknown (%d)' % v).replace(',', ' '))
        lines.append('        <dip bits="%s" name="%s" ids="%s"/>' % (','.join(str(b) for b in bits), name.replace('"', ''), ','.join(ids)))
    head = '    <switches default="%02X,%02X,%02X" base="16">' % (default & 0xFF, (default >> 8) & 0xFF, default >> 16)
    return [head] + lines + ['    </switches>'], default


# the core file per set: one build per board dot clock (Seta2.sv): the machine clock is a whole multiple of it
def rbf_name(setname):
    if setname.startswith('grdians'):
        return 'seta2grd'
    if setname in ('penbros', 'ablast'):
        return 'seta2pen'
    return 'seta2'


def mra_text(setname):
    title, year, maker, ports, fname, folder = GAMES[setname]
    parent = table()[setname]['parent']
    zipattr = '%s.zip|%s.zip' % (setname, parent) if parent else '%s.zip' % setname
    sw, default = switches_lines(setname, ports)
    out = ['<misterromdescription>',
           '    <rotation>horizontal</rotation>',
           '    <name>%s</name>' % title,
           '    <setname>%s</setname>' % setname]
    if parent:
        out.append('    <parent>%s</parent>' % parent)
    out += ['    <mameversion>0289</mameversion>',
            '    <year>%d</year>' % year,
            '    <manufacturer>%s</manufacturer>' % maker,
            '    <players>2</players>',
            '    <joystick>%s</joystick>' % ('0' if setname in ('myangel', 'myangel2', 'mj4simai') else '8'),
            '    <rbf>%s</rbf>' % rbf_name(setname),
            '    <platform>Seta</platform>',
            '',
            '    <!--',
            '      Image for the seta2 core (rtl/s2_mem.sv, tools/seta2_image.py):',
            '',
            '        0x0000000  header: configuration bytes (0x00..0x3F), 93C46 image (0x100..0x17F)',
            '        0x0100000  TMP68301 program (68000 byte order; gundamex 0x500000-0x57FFFF at +0x200000)',
            '        0x0500000  X1-010 samples',
            '        0x0900000  graphics ROM (MAME\'s "video" region as it is)',
            '',
            '      Made by tools/make_mra.py from MAME 0.289 (src/mame/seta/seta2.cpp); expects the MAME 0.289 merged romset or',
            '      the split sets: parts are found by name and CRC.',
            '',
            '      DIP switches (ioctl index 254): byte 0 is DSW1 (MAME\'s DSW1 port, bits 7:0), byte 1 DSW2, byte 2 board',
            '      jumpers; a 1 is "off".  MAME\'s default is %06X.' % default,
            '    -->']
    out += sw
    # address=: fast load -- a recent Main_MiSTer copies the assembled image into the DDR3 at that byte address and sends an empty
    # download instead of the bytes (rtl/s2_mem.sv uses it there); an older one ignores the attribute
    out += ['', '    <rom index="0" zip="%s" md5="None" address="0x30000000">' % zipattr]
    out += rom_lines(setname)
    names = BUTTONS[setname]
    used = [n for n in names]
    defaults = []
    pad = ['A', 'B', 'X', 'Y']
    for n, p in zip(names, pad):
        if n != '-':
            defaults.append(p)
    buttons = '    <buttons names="%s" default="%s"/>' % (','.join(used + ['Start', 'Coin']),
                                                       ','.join(defaults + ['Start', 'Select']))
    out += ['    </rom>', '', buttons, '</misterromdescription>', '']
    return '\n'.join(out), default


def main(argv):
    import mra_build
    outdir = argv[1] if len(argv) > 1 else os.path.join(paths.REPO, 'mra')
    bad = 0
    for s in seta2_rom.PHASE1:
        text, default = mra_text(s)
        title, _, _, _, fname, folder = GAMES[s]
        parent = table()[s]['parent']
        d = os.path.join(outdir, folder) if folder else outdir
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, fname + '.mra')
        open(path, 'w', encoding='utf-8', newline='\n').write(text)
        zips = '|'.join(os.path.join(paths.ROMS, n + '.zip') for n in ([s, parent] if parent else [s])
                        if os.path.exists(os.path.join(paths.ROMS, n + '.zip')))
        md5 = mra_build.mister_md5(path, zips)
        text = text.replace('md5="None"', 'md5="%s"' % md5, 1)
        open(path, 'w', encoding='utf-8', newline='\n').write(text)
        img, md5_check = mra_build.build(path, zips)
        ok = img == bytes(IMG.build(s)) and md5_check == md5
        bad += 0 if ok else 1
        print('%-10s %-55s %s, MiSTer md5 %s, DSW default %06X' % (s, os.path.relpath(path, outdir),
              'image identical' if ok else 'IMAGE DIFFERS (%d vs %d bytes)' % (len(img), len(IMG.build(s))), md5, default))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
