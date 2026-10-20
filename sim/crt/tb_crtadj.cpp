// Unit bench of rtl/s2_crtadj.sv (+ modules/crt_adjust/crt_adjust.sv), after the Metro core's sim/tb_crtadj.cpp: a seta2 raster goes in (the line starts with the horizontal
// sync at dot 0; the picture at dots h0 .. h0 + w - 1 of lines v0 .. v0 + vh - 1; the vertical sync on lines 0 .. vs), the stream that comes out is measured (run.sh).  Every
// picture dot carries its x and its line in the colour, so the content can be followed through the buffer.  Built once per DOT_DIV (the build's clocks per dot); the rasters
// are the MRAs' with the OSD's "Sync widths: Standard" caps.
//   off            : the output equals the input in every clock;
//   on, 0 / 0 / 0  : the same picture, every dot once and in order, the line length, the dot length, the sync's length and the picture's place in the line and in the frame
//                    unchanged (the buffer's line of delay is taken back by the vertical sync);
//   H-Size n       : every dot lasts DOT_DIV * (64 + n) / 64 clocks, the picture keeps its centre;
//   H-Position n   : the picture moves n dots;
//   V-Shift n      : the picture moves n lines down (the vertical sync n lines earlier), also in Gundam EX's 261-line frame;
//   every frame keeps its lines and their length, every picture line comes out whole.
#include "Vs2_crtadj.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cmath>

static Vs2_crtadj* t;

struct Ras { const char* name; int ht, vt, hs, h0, w, v0, vh, vs; };
struct Cfg { int on, hsize, hpos, vshift; };
struct Sample { long long clk; int hb, vb, hs, vs, rgb; };

static int DD = DOT_DIV;

struct Raster {
    const Ras& R; int dot = 0, line = 0, sub = 0;
    Raster(const Ras& r) : R(r) {}
    void step() { if (++sub == DD) { sub = 0; if (++dot == R.ht) { dot = 0; if (++line == R.vt) line = 0; } } }
    bool ce() const { return sub == 0; }
    bool hblank() const { return !(dot >= R.h0 && dot < R.h0 + R.w); }
    bool vblank() const { return !(line >= R.v0 && line < R.v0 + R.vh); }
    bool hs() const { return dot <= R.hs; }
    bool vs() const { return line <= R.vs; }
    int rgb() const { if (hblank() || vblank()) return 0; return ((dot - R.h0) << 12) | line; }
};

static long long FR(const Ras& r) { return (long long)r.vt * r.ht * DD; }
static long long LN(const Ras& r) { return (long long)r.ht * DD; }

static std::vector<Sample> run(const Ras& R, const Cfg& c, int frames, long long* offbad) {
    std::vector<Sample> out;
    Raster r(R);
    int bad = 0;
    t->i_on = c.on; t->i_hsize_f = c.hsize & 31; t->i_hpos_f = c.hpos >= 0 ? c.hpos : 97 + c.hpos; t->i_vshift_f = c.vshift & 31;
    t->i_hstart = R.h0; t->i_hwidth = R.w; t->i_vtotal = R.vt;
    long long total = frames * FR(R);
    for (long long n = 0; n < total; n++) {
        t->i_ce = r.ce(); t->i_hblank = r.hblank(); t->i_vblank = r.vblank(); t->i_hs = r.hs(); t->i_vs = r.vs(); t->i_rgb = r.rgb();
        t->clk = 0; t->eval();            // (the first dot is not compared: the switch from the run before takes effect at a dot) the outputs of this clock, before its edge: what arcade_video's flip-flops capture at the edge
        if (offbad && n > DD && ((int)t->o_ce != (int)r.ce() || (int)t->o_hblank != (int)r.hblank() || (int)t->o_vblank != (int)r.vblank() || (int)t->o_hs != (int)r.hs() ||
                       (int)t->o_vs != (int)r.vs() || (int)t->o_rgb != r.rgb())) bad++;
        if (t->o_ce) out.push_back({n, (int)t->o_hblank, (int)t->o_vblank, (int)t->o_hs, (int)t->o_vs, (int)t->o_rgb});
        t->clk = 1; t->eval();
        r.step();
    }
    if (offbad) *offbad = bad;
    return out;
}

struct Meas {
    int lines = 0;                      // picture lines measured
    double line_clk = 0, hs_clk = 0;    // clocks from one sync rise to the next; the sync's length
    int act = 0, order_ok = 1;          // picture dots of a line; every line 0 .. w-1 in order and from one source line
    double dot_clk = 0;                 // clocks per picture dot
    double first_clk = 0, centre_clk = 0;  // clocks from the sync rise to the first picture dot / to the middle of the picture
    long long vs_clk = -1;              // the first vertical sync rise of frame 3, from the frame's start
    int v_first = -1;                   // sync rises from that vertical sync rise to the first picture line
};

static Meas measure(const Ras& R, const std::vector<Sample>& s) {
    Meas m;
    std::vector<size_t> hsr;
    for (size_t i = 1; i < s.size(); i++) if (s[i].hs && !s[i - 1].hs) hsr.push_back(i);
    int n = 0; double lsum = 0, hsum = 0, dsum = 0, fsum = 0, csum = 0;
    for (size_t k = 0; k + 1 < hsr.size() && n < 150; k++) {
        size_t a = hsr[k], b = hsr[k + 1];
        long long c0 = s[a].clk, c1 = s[b].clk;
        if (c0 < 3 * FR(R)) continue;
        int cnt = 0, expect = 0, srcline = -1; long long first = -1, last = -1;
        for (size_t i = a; i < b; i++) {
            if (!s[i].hb && !s[i].vb) {
                int x = s[i].rgb >> 12, ln = s[i].rgb & 0xFFF;
                if (first < 0) first = s[i].clk;
                if (x != expect) m.order_ok = 0;
                if (srcline < 0) srcline = ln; else if (ln != srcline) m.order_ok = 0;
                expect = x + 1; last = s[i].clk; cnt++;
            }
        }
        if (cnt == 0) continue;
        if (cnt != R.w) m.order_ok = 0;
        n++; lsum += c1 - c0; fsum += first - c0; dsum += (double)(last - first) / (cnt - 1); csum += (first + last) / 2.0 - c0;
        size_t j = a; while (j < b && s[j].hs) j++;
        hsum += (double)(s[j].clk - c0);
        m.act = cnt;
    }
    if (n) { m.lines = n; m.line_clk = lsum / n; m.hs_clk = hsum / n; m.dot_clk = dsum / n; m.first_clk = fsum / n; m.centre_clk = csum / n; }
    for (size_t i = 1; i < s.size(); i++) if (s[i].vs && !s[i - 1].vs && s[i].clk >= 3 * FR(R)) {
        m.vs_clk = s[i].clk - 3 * FR(R);
        int h = 0;
        for (size_t j = i; j < s.size(); j++) {
            if (j > i && s[j].hs && !s[j - 1].hs) h++;
            if (!s[j].hb && !s[j].vb) { m.v_first = h; break; }
        }
        break;
    }
    return m;
}

static int fails = 0;
static void check(const char* what, bool ok, const char* fmt = "", double a = 0, double b = 0) {
    printf("  %-78s %s", what, ok ? "ok" : "FAIL");
    if (fmt[0]) { printf("   ("); printf(fmt, a, b); printf(")"); }
    printf("\n");
    if (!ok) fails++;
}

// the H-Size values whose picture still fits between the end of the sync and the end of the line, about its centre
static bool hsize_fits(const Ras& R, int n) {
    double c = R.h0 + R.w / 2.0, half = R.w / 2.0 * (64 + n) / 64.0;
    return c + half < R.ht - 1 && c - half > R.hs + 2;
}

static void frame_checks(const Ras& R, const Cfg& cf) {
    auto s = run(R, cf, 6, nullptr);
    // every frame: vt sync rises between vertical sync rises, each frame vt * ht * DD clocks
    std::vector<long long> vsr; std::vector<int> hsn; int hsc = 0;
    for (size_t i = 1; i < s.size(); i++) {
        if (s[i].hs && !s[i - 1].hs) hsc++;
        if (s[i].vs && !s[i - 1].vs) { vsr.push_back(s[i].clk); hsn.push_back(hsc); hsc = 0; }
    }
    bool ok = vsr.size() >= 4; long long mn = 1LL << 60, mx = 0; int hmn = 1 << 30, hmx = 0;
    for (size_t k = 2; k + 1 < vsr.size(); k++) {
        long long p = vsr[k + 1] - vsr[k]; mn = p < mn ? p : mn; mx = p > mx ? p : mx;
        hmn = hsn[k + 1] < hmn ? hsn[k + 1] : hmn; hmx = hsn[k + 1] > hmx ? hsn[k + 1] : hmx;
    }
    char w[120];
    snprintf(w, sizeof w, "H-Size %+d H-Position %+d V-Shift %+d: every frame %d lines of %lld clocks", cf.hsize, cf.hpos, cf.vshift, R.vt, LN(R));
    check(w, ok && mn == FR(R) && mx == FR(R) && hmn == R.vt && hmx == R.vt, "frame %g clocks, %g lines", (double)mn, (double)hmn);
    // the picture lines of frame 4: vh lines of w dots, the others empty
    std::vector<int> per; int cnt = 0; bool started = false; long long f4 = 4 * FR(R), f5 = 5 * FR(R);
    for (size_t i = 1; i < s.size(); i++) {
        if (s[i].clk < f4 || s[i].clk >= f5) continue;
        if (s[i].hs && !s[i - 1].hs) { if (started) per.push_back(cnt); started = true; cnt = 0; }
        if (started && !s[i].hb && !s[i].vb) cnt++;
    }
    int full = 0, part = 0;
    for (int p : per) { if (p == R.w) full++; else if (p) part++; }
    snprintf(w, sizeof w, "H-Size %+d H-Position %+d V-Shift %+d: %d lines of %d dots, the others empty", cf.hsize, cf.hpos, cf.vshift, R.vh, R.w);
    check(w, full == R.vh && part == 0, "%g full, %g partial", (double)full, (double)part);
}

static void bench(const Ras& R) {
    printf("== %s: %d x %d dots of %d clocks, picture %d x %d at (%d, %d), sync to dot %d / line %d\n", R.name, R.ht, R.vt, DD, R.w, R.vh, R.h0, R.v0, R.hs, R.vs);
    long long bad = 0;
    auto so = run(R, {0, 0, 0, 0}, 4, &bad);
    check("off: every output equals its input in every clock", bad == 0, "%g mismatches", (double)bad);
    Meas nat = measure(R, so);
    printf("    (native: first dot %.0f clocks after the sync rise, vertical sync %lld clocks into the frame, picture from sync rise %d after it)\n", nat.first_clk, nat.vs_clk, nat.v_first);

    Meas b0 = measure(R, run(R, {1, 0, 0, 0}, 5, nullptr));
    char w[120];
    check("on 0/0/0: the line length unchanged", b0.line_clk == LN(R), "%g clocks", b0.line_clk);
    snprintf(w, sizeof w, "on 0/0/0: %d picture dots, in order, from one source line", R.w);
    check(w, b0.act == R.w && b0.order_ok, "%g dots", (double)b0.act);
    check("on 0/0/0: every dot lasts DOT_DIV clocks", fabs(b0.dot_clk - DD) < 0.01, "%g", b0.dot_clk);
    check("on 0/0/0: the horizontal sync as long as before", fabs(b0.hs_clk - nat.hs_clk) <= DD, "%g, was %g", b0.hs_clk, nat.hs_clk);
    check("on 0/0/0: the picture starts where it started (within a dot)", fabs(b0.first_clk - nat.first_clk) <= DD, "%g, was %g", b0.first_clk, nat.first_clk);
    // the buffer delays the picture a line, and the vertical sync with it: the picture keeps its place in the frame
    check("on 0/0/0: the vertical sync a line (and two dots) after the input's", b0.vs_clk - nat.vs_clk >= LN(R) && b0.vs_clk - nat.vs_clk <= LN(R) + 3 * DD,
          "%g, was %g", (double)b0.vs_clk, (double)nat.vs_clk);
    check("on 0/0/0: the picture as many lines after the vertical sync", b0.v_first == nat.v_first, "%g, was %g", (double)b0.v_first, (double)nat.v_first);

    for (int hs : {1, 4, 8, 15, -1, -8, -16}) {
        if (!hsize_fits(R, hs)) { printf("  H-Size %+d: the picture would not fit the line (not a check)\n", hs); continue; }
        Meas m = measure(R, run(R, {1, hs, 0, 0}, 5, nullptr));
        double exp = DD * (64 + hs) / 64.0;
        snprintf(w, sizeof w, "H-Size %+d: %d dots in order, every dot %.3f clocks, the line unchanged", hs, R.w, exp);
        check(w, m.act == R.w && m.order_ok && m.line_clk == LN(R) && fabs(m.dot_clk - exp) < 0.05, "dot %.3f, line %g", m.dot_clk, m.line_clk);
        snprintf(w, sizeof w, "H-Size %+d: the picture keeps its centre (within a dot)", hs);
        check(w, fabs(m.centre_clk - nat.centre_clk) <= DD, "centre %.1f, was %.1f", m.centre_clk, nat.centre_clk);
    }
    for (int hp : {8, 16, -8, -32, -48}) {
        Meas m = measure(R, run(R, {1, 0, hp, 0}, 5, nullptr));
        if (R.h0 + hp + R.w >= R.ht - 1 || R.h0 + hp <= R.hs + 2) { printf("  H-Position %+d: the picture would leave the line (not a check)\n", hp); continue; }
        snprintf(w, sizeof w, "H-Position %+d: %d dots in order, %+d dots from where it started", hp, R.w, hp);
        check(w, m.act == R.w && m.order_ok && m.line_clk == LN(R) && fabs((m.first_clk - b0.first_clk) - hp * DD) <= DD, "moved %g clocks", m.first_clk - b0.first_clk);
    }
    // the vertical sync (lines 0 .. vs) moved n lines must stay outside the picture: down by at most the lines under the picture, up by at most those above it
    int bottom = R.vt - (R.v0 + R.vh), top = R.v0 - R.vs - 1;
    printf("    (the vertical sync has %d lines of room under the picture and %d above it: V-Shift %+d .. %+d)\n", bottom, top, -top, bottom);
    for (int vs : {1, 5, 7, 15, -1, -5, -11, -16}) {
        if (vs > bottom || -vs > top) { printf("  V-Shift %+d: the vertical sync would fall into the picture (not a check)\n", vs); continue; }
        Meas m = measure(R, run(R, {1, 0, 0, vs}, 5, nullptr));
        snprintf(w, sizeof w, "V-Shift %+d: the picture %+d lines from the vertical sync", vs, vs);
        check(w, m.v_first == b0.v_first + vs && m.act == R.w && m.line_clk == LN(R), "%g lines, was %g", (double)m.v_first, (double)b0.v_first);
    }
    // whole frames, whole picture lines: settings that keep the picture inside the line and the vertical sync outside the picture
    std::vector<Cfg> cfs = {{1, 0, 0, 0}, {1, -6, 8, 3}, {1, 4, -4, -2}, {1, 0, 0, bottom}, {1, 0, 0, -top}};
    for (auto& cf : cfs) {
        if (cf.hsize && !hsize_fits(R, cf.hsize)) continue;
        if (cf.vshift > 15) cf.vshift = 15;
        if (cf.vshift < -16) cf.vshift = -16;
        frame_checks(R, cf);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vs2_crtadj;
    for (int i = 0; i < 4; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    //                       name                  ht   vt  hs   h0    w  v0   vh vs
    static const Ras grd  = {"Guardians",         409, 262, 28,  89, 304, 20, 232, 2};
    static const Ras pen  = {"Penguin Brothers",  445, 262, 32, 101, 320, 15, 224, 2};
    static const Ras gx   = {"Gundam EX",         519, 261, 37, 112, 384, 23, 224, 2};
    static const Ras mj   = {"Mahjong Yonshimai", 517, 262, 32, 101, 384, 15, 240, 2};
    static const Ras myg  = {"My Angel",          513, 262, 30,  93, 376, 15, 240, 2};
    if (DD == 15) bench(grd);
    else if (DD == 13) bench(pen);
    else { bench(gx); bench(mj); bench(myg); }
    printf(fails ? "crtadj bench (DOT_DIV %d): %d FAILURES\n" : "crtadj bench (DOT_DIV %d): all ok (%d failures)\n", DD, fails);
    delete t;
    return fails ? 1 : 0;
}
