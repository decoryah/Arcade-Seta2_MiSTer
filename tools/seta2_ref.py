#!/usr/bin/env python3
"""Reference renderer of the Allumer X1-020 / NEC DX-101 video chip (seta2.cpp), written out from MAME 0.289's
src/devices/video/x1_020_dx_101.cpp (screen_update, draw_sprites, draw_sprites_line, drawgfx_line, draw_pixel, get_tile,
the register 0x26 list copy) and checked against the pixels MAME drew from the same state (tools/capture.py).

    seta2_ref.py <set> <statedir> [frame ...] [--png outdir] [--stats]

  compares every captured frame (or the ones named) with MAME's picture: prints the number of differing pixels.
  --png    writes ref / mame / diff pictures of the differing frames
  --stats  per frame: the most 8-pixel tile rows any line draws (inside / outside the screen), the list entries, the
           highest tile code: what the RTL's fetch has to sustain

The state files are tools/lua/dump_state.lua's.  The graphics come from work/regions/<set>/video.bin (tools/seta2_rom.py
build, or MAME's own dump_regions.lua: they are identical).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import pngio

M32 = 0xffffffff


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def words_le(b):
    return list(struct.unpack('<%dH' % (len(b) // 2), b))


# ---------------------------------------------------------------- the list copy at register 0x26 / 0x24 (vregs_w)
def private_list(lst):
    """MAME's m_private_spriteram after the copy, from the display list (sprite RAM 0x3000-0x3fff) at the time of the write.
    The entries after the end marker keep older values in MAME; draw_sprites_line stops at the marker, so they are left 0."""
    priv = [0] * 0x800
    cur = 0
    for i in range(0, 0x800, 4):
        num = priv[i] = lst[i]
        priv[i + 1] = lst[i + 1]
        priv[i + 2] = lst[i + 2]
        sprite = lst[i + 3]
        priv[i + 3] = ((cur // 4) & 0x7fff) | (sprite & 0x8000)
        for _ in range((num & 0xff) + 1):
            if cur < 0x3000 // 2:
                cur += 4
        if priv[i] & 0x8000:
            if sprite == 0:
                priv[i + 3] |= 0x4000           # MAME's penbros hack: an invalid pointer, filtered when drawing
            break
    return priv


def list_copy(spr, priv):
    """vregs_w case 0x24 / 0x26 on the sprite RAM `spr` (modified in place) and the private list `priv` (modified in place)"""
    cur = 0
    for i in range(0, 0x800, 4):
        num = priv[i] = spr[0x1800 + i]
        priv[i + 1] = spr[0x1800 + i + 1]
        priv[i + 2] = spr[0x1800 + i + 2]
        sprite = spr[0x1800 + i + 3]
        priv[i + 3] = ((cur // 4) & 0x7fff) | (sprite & 0x8000)
        list2addr = (sprite & 0x7fff) * 4
        for j in range((num & 0xff) + 1):
            if cur < 0x3000 // 2:
                for k in range(4):
                    spr[cur + k] = spr[(list2addr + j * 4 + k) & 0x1ffff]
                cur += 4
        if priv[i] & 0x8000:
            if sprite == 0:
                priv[i + 3] |= 0x4000
            break


# ---------------------------------------------------------------- graphics
class Gfx:
    """the 8x8 8bpp tiles of the "video" region: tile_layout (planes {56,48,..,0}, x 0..7, rows 64 bits apart):
    byte q of a row is bit plane q of the pen, pixel x is bit 7-x of each byte"""
    def __init__(self, data):
        self.data = data
        self.elements = len(data) // 64
        self.cache = {}

    def tile(self, code):
        code %= self.elements                     # m_realtilenumber[i] = i % elements
        t = self.cache.get(code)
        if t is None:
            base = code * 64
            d = self.data
            t = []
            for row in range(8):
                rb = d[base + row * 8: base + row * 8 + 8]
                px = []
                for x in range(8):
                    m = 0x80 >> x
                    v = 0
                    for q in range(8):
                        if rb[q] & m:
                            v |= 1 << q
                    px.append(v)
                t.append(px)
            self.cache[code] = t
        return t


# mask, shift, shadow per colour depth ("which_gfx", list word 0 bits 10..8)
BPP_MASK_TABLE = [(0xff, 0, 4), (0x30, 4, 2), (0x07, 0, 3), (0xff, 0, 0), (0x0f, 0, 3), (0xf0, 4, 4), (0x3f, 0, 5), (0xff, 0, 8)]


class Stats:
    def __init__(self):
        self.rows = 0            # drawgfx_line calls on the current line
        self.max_rows = 0
        self.max_code = 0
        self.entries = 0
        self.codes = set()


def drawgfx_line(dest, minx, maxx, which_gfx, tile, realcolor, flipx, flipy, base_sx, xzoom, use_shadow, line, opaque, st):
    gfx_mask, gfx_shift, shadow = BPP_MASK_TABLE[which_gfx]
    if not use_shadow:
        shadow = 0
    minx <<= 16
    maxx <<= 16
    if flipy:
        line = 7 - line
    source = tile[line]
    if st is not None:
        st.rows += 1

    def draw_pixel(sx, column):
        if minx <= sx < maxx:
            realsx = sx >> 16
            pen = (source[column] & gfx_mask) >> gfx_shift
            if pen or opaque:
                if not shadow:
                    dest[realsx] = (realcolor + pen) & 0x7fff
                else:
                    pen_shift = 15 - shadow
                    pen_mask = (1 << pen_shift) - 1
                    dest[realsx] = ((dest[realsx] & pen_mask) | (pen << pen_shift)) & 0x7fff

    if xzoom < 0x10000:                           # shrink
        x0 = s32(base_sx + 8 * xzoom - xzoom) if flipx else base_sx
        x1 = s32(base_sx - xzoom) if flipx else s32(x0 + 8 * xzoom)
        dx = -xzoom if flipx else xzoom
        sx, column = x0, 0
        while sx != x1:
            draw_pixel(sx, column)
            sx = s32(sx + dx)
            column += 1
    else:                                         # enlarge or no zoom
        x0 = base_sx
        x1 = s32(x0 + 8 * xzoom)
        inc = -1 if flipx else 1
        column = 7 if flipx else 0
        countx = 0
        sx = x0
        while sx < x1:
            draw_pixel(sx, column)
            countx += 0x10000
            if countx >= xzoom:
                column += inc
                countx -= xzoom
            sx += 0x10000


def get_tile(spr, is_16x16, x, y, page):
    xtile = x >> (4 if is_16x16 else 3)
    ytile = y >> (4 if is_16x16 else 3)
    ytile ^= 0x1f                                 # "yes the tilemap in RAM is flipped?!"
    i = 2 * ((page * 0x2000 // 4) + ((ytile & 0x1f) << 6) + (xtile & 0x03f))
    attr = spr[i]
    code = spr[i + 1] + ((attr & 0x0007) << 16)
    flipx = (attr >> 4) & 1
    flipy = (attr >> 3) & 1
    color = (attr & 0xffe0) >> 5
    if is_16x16:
        code &= ~3
        if not flipx:
            if x & 8:
                code += 1
        else:
            if not (x & 8):
                code += 1
        if not flipy:
            if y & 8:
                code += 2
        else:
            if not (y & 8):
                code += 2
    return code, flipx, flipy, color


def draw_sprites_line(dest, minx, maxx, priv, spr, gfx, scanline, realscanline, xoffset, xzoom, st):
    for e in range(0, 0x800, 4):
        num, xoffs, yoffs, sprite = priv[e], priv[e + 1], priv[e + 2], priv[e + 3]
        s2b = (sprite & 0x7fff) * 4
        global_sizex = xoffs & 0xfc00
        global_sizey = yoffs & 0xfc00
        nozoom = (num >> 14) & 1
        opaque = (num >> 13) & 1
        use_global_size = (num >> 12) & 1
        use_shadow = (num >> 11) & 1
        which_gfx = (num & 0x0700) >> 8
        xoffs &= 0x3ff
        yoffs &= 0x3ff
        if yoffs & 0x200:
            yoffs -= 0x400
        global_xoffset = 0x80 if nozoom else 0
        global_yoffset = -0x90 if nozoom else 0
        if nozoom:
            use_shadow = 0
            usedscanline = realscanline
            usedxzoom = 0x10000
            usedxoffset = 0
        else:
            usedscanline = scanline
            usedxzoom = xzoom
            usedxoffset = xoffset
        n = (num & 0xff) + 1
        if (sprite & 0x7fff) < 0x3000 // 2 // 4:
            for k in range(n):
                s2 = s2b + 4 * k
                if s2 >= 0x20000:
                    break
                w0, w1, w2, w3 = spr[s2], spr[s2 + 1], spr[s2 + 2], spr[s2 + 3]
                if sprite & 0x8000:
                    # "floating tilemap" sprite
                    sy = w1 & 0x3ff
                    sy += global_yoffset
                    sy &= 0x3ff
                    if sy & 0x200:
                        sy -= 0x400
                    local_sizey = w1 & 0xfc00
                    height = global_sizey if use_global_size else local_sizey
                    height = ((height & 0xfc00) >> 10) + 1
                    firstline = (sy + yoffs) & 0x3ff
                    if firstline & 0x200:
                        firstline -= 0x400
                    endline = firstline + height * 0x10 - 1
                    if endline & 0x200:
                        endline -= 0x400
                    if endline >= firstline:
                        if firstline > usedscanline or endline < usedscanline:
                            continue
                    else:
                        if usedscanline > endline and usedscanline < firstline:
                            continue
                    sx = w0
                    local_sizex = sx & 0xfc00
                    sx &= 0x3ff
                    sx -= global_xoffset
                    width = global_sizex if use_global_size else local_sizex
                    width = (width & 0xfc00) >> 10
                    if not width:
                        continue
                    firstcolumn = sx + xoffs
                    firstcolumn = (firstcolumn & 0x1ff) - (firstcolumn & 0x200)
                    lastcolumn = firstcolumn + width * 0x10 - 1
                    if firstcolumn > maxx - 1:
                        continue
                    if lastcolumn < minx:
                        continue
                    scrolly = w3 & 0x1ff
                    scrolly += global_yoffset
                    sourceline = (usedscanline - scrolly) & 0x1ff
                    scrollx = w2
                    is_16x16 = (scrollx >> 15) & 1
                    page = (scrollx & 0x7c00) >> 10
                    scrollx &= 0x3ff
                    tileline = sourceline & 0x07
                    dx = sx + scrollx + xoffs + 0x10
                    for x in range(0x80):
                        px = (((dx + x * 8) + 0x10) & 0x3ff) - 0x10
                        dst_x = px & 0x3ff
                        dst_x = (dst_x & 0x1ff) - (dst_x & 0x200)
                        if dst_x >= firstcolumn - 8 and dst_x <= lastcolumn:
                            code, flipx, flipy, color = get_tile(spr, is_16x16, x * 8, sourceline, page)
                            realsx = s32((dst_x - (usedxoffset >> 16)) * usedxzoom)
                            if st is not None:
                                st.codes.add(code % gfx.elements)
                            drawgfx_line(dest, minx, maxx, which_gfx, gfx.tile(code), color << 4, flipx, flipy, realsx,
                                         usedxzoom, use_shadow, tileline, opaque, st)
                else:
                    # "normal" sprite
                    sy = w1 & 0x1ff
                    if sy & 0x100:
                        sy -= 0x200
                    sy += global_yoffset
                    sy &= 0x3ff
                    sizey = global_sizey if use_global_size else (w1 & 0xfc00)
                    sizey = (1 << ((sizey & 0x0c00) >> 10)) - 1
                    firstline = (sy + yoffs) & 0x3ff
                    endline = (firstline + (sizey + 1) * 8) - 1
                    endline &= 0x3ff
                    if firstline & 0x200:
                        firstline -= 0x400
                    if endline & 0x200:
                        endline -= 0x400
                    if endline >= firstline:
                        if firstline > usedscanline or endline < usedscanline:
                            continue
                    else:
                        if usedscanline > endline and usedscanline < firstline:
                            continue
                    attr = w2
                    code = w3 + ((attr & 0x0007) << 16)
                    flipx = (attr >> 4) & 1
                    flipy = (attr >> 3) & 1
                    color = (attr & 0xffe0) >> 5
                    sx = w0
                    sizex = global_sizex if use_global_size else sx
                    sizex = (1 << ((sizex & 0x0c00) >> 10)) - 1
                    sx += xoffs
                    sx = (sx & 0x1ff) - (sx & 0x200)
                    sx -= global_xoffset
                    line = usedscanline - firstline
                    y = line >> 3
                    line &= 0x7
                    if nozoom:
                        color = 0x7ff
                    code &= ~((sizex + 1) * (sizey + 1) - 1)
                    basecode = code + ((sizey - y) if flipy else y) * (sizex + 1) + (sizex if flipx else 0)
                    code_inc = -1 if flipx else 1
                    for x in range(sizex + 1):
                        realsx = s32(((sx + x * 8) - (usedxoffset >> 16)) * usedxzoom)
                        if st is not None:
                            st.codes.add(basecode % gfx.elements)
                        drawgfx_line(dest, minx, maxx, which_gfx, gfx.tile(basecode), color << 4, flipx, flipy, realsx,
                                     usedxzoom, use_shadow, line, opaque, st)
                        basecode += code_inc
        if num & 0x8000:
            break


def render(vr, priv, spr, gfx, w, h, st=None):
    """-> list of h rows of w palette indexes (screen_update + draw_sprites)"""
    bitmap = [[0] * w for _ in range(h)]          # bitmap.fill(palette().pen(0))
    render_lines(bitmap, vr, priv, spr, gfx, w, 0, h - 1, st)
    return bitmap


def render_lines(bitmap, vr, priv, spr, gfx, w, ylo, yhi, st=None):
    """screen_update for the lines ylo..yhi (a partial update): fill with pen 0, draw unless blanked"""
    for y in range(ylo, yhi + 1):
        bitmap[y][:] = [0] * w
    if vr[0x30 // 2] & 1:                         # blank screen
        return
    yoffset = ((vr[0x1a // 2] << 16) | vr[0x18 // 2]) & 0x07ffffff
    yoffset = 0x07ffffff - yoffset
    yzoom = ((vr[0x1e // 2] << 16) | vr[0x1c // 2]) & 0x07ffffff
    yinv = False
    if yzoom & 0x04000000:
        yzoom = 0x8000000 - yzoom
        yinv = True
    xoffset = ((vr[0x12 // 2] << 16) | vr[0x10 // 2]) & 0x07ffffff
    if xoffset & 0x04000000:
        xoffset -= 0x08000000
    xzoom = (vr[0x16 // 2] << 16) | vr[0x14 // 2]
    if xzoom & 0x04000000:
        xzoom = (0x8000000 - xzoom) & M32
    if not xzoom:
        return
    inc2 = ((1 << 32) // xzoom) & M32
    for y in range(ylo, yhi + 1):
        if not yinv:
            yy = y
        else:
            yy = ((y * yzoom + yoffset) & 0x07ffffff) >> 16
            if yy & 0x400:
                yy -= 0x800
        if st is not None:
            st.rows = 0
        draw_sprites_line(bitmap[y], 0, w, priv, spr, gfx, yy, y, xoffset, inc2, st)
        if st is not None:
            st.max_rows = max(st.max_rows, st.rows)


def pal_rgb(pal):
    """xRGB_555 -> (r, g, b), pal5bit"""
    out = []
    for v in pal:
        r, g, b = (v >> 10) & 31, (v >> 5) & 31, v & 31
        out.append(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))
    return out


def load_state(sdir, frame):
    pre = os.path.join(sdir, 'f%05d' % frame)
    st = {}
    st['spr'] = words_le(open(pre + '.spr', 'rb').read())
    st['pal'] = words_le(open(pre + '.pal', 'rb').read())
    st['pal1'] = words_le(open(pre + '.pal1', 'rb').read())
    st['vr'] = words_le(open(pre + '.vr', 'rb').read())
    st['lst'] = words_le(open(pre + '.lst', 'rb').read()) if os.path.exists(pre + '.lst') else None
    txt = open(pre + '.txt').read().split('\n')
    w, h = [int(x) for x in txt[2].split()[1:3]]
    st['w'], st['h'] = w, h
    st['rgb'] = open(pre + '.rgb', 'rb').read()
    return st


def frames_in(sdir):
    return sorted(int(f[1:6]) for f in os.listdir(sdir) if f.endswith('.rgb'))


def picture(bitmap, pal):
    cols = pal_rgb(pal)
    out = bytearray()
    for row in bitmap:
        for i in row:
            out += bytes(cols[i])
    return out


def compare(setname, sdir, frames, png=None, stats=False):
    gfx = Gfx(open(os.path.join(paths.WORK, 'regions', setname, 'video.bin'), 'rb').read())
    total_bad = 0
    for fr in frames:
        s = load_state(sdir, fr)
        priv = private_list(s['lst']) if s['lst'] else [0] * 0x800
        st = Stats() if stats else None
        bm = render(s['vr'], priv, s['spr'], gfx, s['w'], s['h'], st)
        ref = picture(bm, s['pal1'])
        mame = s['rgb']
        bad = sum(1 for i in range(0, len(ref), 3) if ref[i:i + 3] != mame[i:i + 3])
        total_bad += bad
        line = 'frame %5d: %6d differing pixels' % (fr, bad)
        if st is not None:
            line += '  max tile rows/line %4d  max code %05x  codes %d' % (st.max_rows, max(st.codes) if st.codes else 0,
                                                                          len(st.codes))
        print(line)
        sys.stdout.flush()
        if png and bad:
            os.makedirs(png, exist_ok=True)
            pngio.write(os.path.join(png, '%s_%05d_ref.png' % (setname, fr)), s['w'], s['h'], ref)
            pngio.write(os.path.join(png, '%s_%05d_mame.png' % (setname, fr)), s['w'], s['h'], mame)
            diff = bytearray()
            for i in range(0, len(ref), 3):
                diff += b'\xff\x00\xff' if ref[i:i + 3] != mame[i:i + 3] else bytes(x // 3 for x in mame[i:i + 3])
            pngio.write(os.path.join(png, '%s_%05d_diff.png' % (setname, fr)), s['w'], s['h'], diff)
    print('%s: %d frames, %d differing pixels' % (setname, len(frames), total_bad))
    return total_bad


def main(argv):
    png = None
    if '--png' in argv:
        png = argv[argv.index('--png') + 1]
        argv = [a for a in argv if a not in ('--png', png)]
    stats = '--stats' in argv
    argv = [a for a in argv if a != '--stats']
    if len(argv) < 3:
        print(__doc__)
        return 2
    setname, sdir = argv[1], argv[2]
    frames = [int(x) for x in argv[3:]] or frames_in(sdir)
    return 1 if compare(setname, sdir, frames, png, stats) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
