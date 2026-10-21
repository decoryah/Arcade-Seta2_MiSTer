// Unit bench of rtl/s2_guns.sv (run.sh): the light guns' aim from the stick, the d-pad and the mouse, the ports MAME's lightgun fields
// read, the trigger / pump, and the crosshair drawn into a light-gun raster (446 x 262, the picture 320 x 240; two clocks a dot here).
//   reset           : both guns at the centre, { Y, X } = 0x8075 (v = 0x80);
//   stick, Aim      : -128 .. 127 across the picture, both ends exact (0x25 / 0xC5, 0x08 / 0xF8), held in the dead zone (|a| < 8);
//   stick, Auto     : 96 or more moves as the d-pad does (2 a frame), less absolutely; D-pad: any deflection past the dead zone moves;
//   d-pad           : 2 a frame, held at the ends;
//   mouse           : relative, Y positive up, for the OSD's player only (off: nobody); left button the trigger, right the pump;
//   buttons         : B1 the trigger, B2 the pump, per player;
//   crosshair       : 20 dots around v * 320 / 256, v * 240 / 256 of the picture, red P1 over green P2, only when shown.
#include "Vs2_guns.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <utility>

static Vs2_guns* t;
static int fails = 0;
static const int DD = 2, HT = 446, VT = 262, H0 = 40, W = 320, V0 = 16, VH = 240;

static void check(bool ok, const char* what, long a = 0, long b = 0) {
    if (!ok) { fails++; printf("FAIL %s (%lx, expected %lx)\n", what, a, b); }
}

static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }

// one frame of the raster; the crosshair dots seen (x, y, colour) in the picture
static std::vector<std::pair<std::pair<int, int>, int>> frame() {
    std::vector<std::pair<std::pair<int, int>, int>> dots;
    for (int line = 0; line < VT; line++)
        for (int dot = 0; dot < HT; dot++)
            for (int sub = 0; sub < DD; sub++) {
                bool hb = !(dot >= H0 && dot < H0 + W), vb = !(line >= V0 && line < V0 + VH);
                t->ce = sub == 0; t->hblank = hb; t->vblank = vb; t->rgb_in = 0x000000;
                t->clk = 0; t->eval();
                if (sub == 0 && !hb && !vb && t->rgb_out != 0)
                    dots.push_back({{dot - H0, line - V0}, (int)t->rgb_out});
                t->clk = 1; t->eval();
            }
    return dots;
}

static void frames(int n) { for (int i = 0; i < n; i++) frame(); }
static void settle() { for (int i = 0; i < 8; i++) tick(); }

static int mtog = 0;
static void mouse(int dx, int dy, int btn) {        // one packet: dx right, dy up (-255 .. 255), btn bit 0 left, bit 1 right
    mtog ^= 1;
    t->mouse = (mtog << 24) | ((dy & 0xff) << 16) | ((dx & 0xff) << 8) | ((dy < 0) << 5) | ((dx < 0) << 4) | (btn & 3);
    settle();
}

static int ana(int y, int x) { return ((y & 0xff) << 8) | (x & 0xff); }
static int portx(int v) { return 0x25 + ((v * 161) >> 8); }
static int porty(int v) { return 0x08 + ((v * 241) >> 8); }
static int port(int vy, int vx) { return (porty(vy) << 8) | portx(vx); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vs2_guns;
    t->rst = 1; t->mode0 = 1; t->mode1 = 1; t->ms_who = 2; t->show = 0; t->vblank = 1;   // every frame() then one vblank start
    settle(); t->rst = 0; settle();

    // reset
    check(t->gun1 == 0x8075 && t->gun2 == 0x8075, "reset: centre", t->gun1, 0x8075);
    check(port(0x80, 0x80) == 0x8075, "port formula at the centre", port(0x80, 0x80), 0x8075);
    check(portx(0) == 0x25 && portx(255) == 0xc5 && porty(0) == 0x08 && porty(255) == 0xf8, "port formula ends");

    // stick, Aim
    t->ana0 = ana(-128, -128); settle();
    check(t->gun1 == 0x0825, "Aim: top left", t->gun1, 0x0825);
    t->ana0 = ana(127, 127); settle();
    check(t->gun1 == 0xf8c5, "Aim: bottom right", t->gun1, 0xf8c5);
    t->ana0 = ana(16, -16); settle();
    check(t->gun1 == port(0x90, 0x70), "Aim: (16, -16)", t->gun1, port(0x90, 0x70));
    t->ana0 = ana(7, -7); settle();
    check(t->gun1 == port(0x90, 0x70), "Aim: dead zone holds", t->gun1, port(0x90, 0x70));
    check(t->gun2 == 0x8075, "Aim: P2 untouched", t->gun2, 0x8075);
    t->ana1 = ana(-128, 127); settle();
    check(t->gun2 == 0x08c5, "Aim: P2's stick", t->gun2, 0x08c5);
    t->ana0 = 0; t->ana1 = 0; t->rst = 1; settle(); t->rst = 0; settle();

    // stick, Auto: full deflection moves 2 a frame, less is absolute
    t->mode0 = 0;
    t->ana0 = ana(0, 127); frames(10); settle();
    check(t->gun1 == port(0x80, 0x94), "Auto: full right, 10 frames", t->gun1, port(0x80, 0x94));
    t->ana0 = ana(-100, 0); frames(5); settle();
    check(t->gun1 == port(0x76, 0x94), "Auto: full up, 5 frames", t->gun1, port(0x76, 0x94));
    t->ana0 = ana(0, 40); settle();
    check(t->gun1 == port(0x76, 0xa8), "Auto: part way is absolute", t->gun1, port(0x76, 0xa8));
    t->ana0 = 0;

    // stick, D-pad: any deflection past the dead zone moves
    t->mode0 = 2; t->rst = 1; settle(); t->rst = 0; settle();
    t->ana0 = ana(0, -20); frames(4); settle();
    check(t->gun1 == port(0x80, 0x78), "D-pad mode: small left, 4 frames", t->gun1, port(0x80, 0x78));
    t->ana0 = ana(0, -7); frames(4); settle();
    check(t->gun1 == port(0x80, 0x78), "D-pad mode: dead zone", t->gun1, port(0x80, 0x78));
    t->ana0 = 0; t->mode0 = 1;

    // d-pad: 2 a frame, held at the ends
    t->rst = 1; settle(); t->rst = 0; settle();
    t->joy0 = 1; frames(3); settle();                       // right
    check(t->gun1 == port(0x80, 0x86), "d-pad right, 3 frames", t->gun1, port(0x80, 0x86));
    frames(70); settle();
    check(t->gun1 == port(0x80, 0xff), "d-pad right held at the end", t->gun1, port(0x80, 0xff));
    t->joy0 = 8; frames(70); settle();                      // up
    check(t->gun1 == port(0x00, 0xff), "d-pad up held at the end", t->gun1, port(0x00, 0xff));
    t->joy0 = 4 | 2; frames(2); settle();                   // down + left
    check(t->gun1 == port(0x04, 0xfb), "d-pad down-left, 2 frames", t->gun1, port(0x04, 0xfb));
    t->joy0 = 0;
    t->joy1 = 4; frames(2); settle();
    check(t->gun2 == port(0x84, 0x80), "P2's d-pad", t->gun2, port(0x84, 0x80));
    t->joy1 = 0;

    // mouse
    t->rst = 1; settle(); t->rst = 0; settle();
    t->ms_who = 0;
    mouse(10, 5, 0);
    check(t->gun1 == port(0x7b, 0x8a), "mouse P1: right 10, up 5", t->gun1, port(0x7b, 0x8a));
    mouse(-30, -20, 0);
    check(t->gun1 == port(0x8f, 0x6c), "mouse P1: left 30, down 20", t->gun1, port(0x8f, 0x6c));
    for (int i = 0; i < 4; i++) mouse(-100, 0, 0);
    check(t->gun1 == port(0x8f, 0x00), "mouse P1: held at the left", t->gun1, port(0x8f, 0x00));
    check(t->gun2 == 0x8075, "mouse P1: P2 untouched", t->gun2, 0x8075);
    mouse(0, 0, 1);
    check(t->trig == 1 && t->pump == 0, "mouse P1: left button triggers", t->trig, 1);
    mouse(0, 0, 2);
    check(t->trig == 0 && t->pump == 1, "mouse P1: right button pumps", t->pump, 1);
    mouse(0, 0, 0);
    t->ms_who = 1;
    mouse(20, 0, 1);
    check(t->gun2 == port(0x80, 0x94) && t->trig == 2, "mouse P2: moves gun 2, its trigger", t->gun2, port(0x80, 0x94));
    check(t->gun1 == port(0x8f, 0x00), "mouse P2: P1 untouched", t->gun1, port(0x8f, 0x00));
    mouse(0, 0, 0);
    t->ms_who = 2;
    mouse(20, 20, 3);
    check(t->gun1 == port(0x8f, 0x00) && t->gun2 == port(0x80, 0x94) && t->trig == 0 && t->pump == 0, "mouse off: nothing");
    mouse(0, 0, 0);

    // buttons
    t->joy0 = 0x10; settle(); check(t->trig == 1 && t->pump == 0, "P1 B1: trigger", t->trig, 1);
    t->joy0 = 0x20; settle(); check(t->trig == 0 && t->pump == 1, "P1 B2: pump", t->pump, 1);
    t->joy0 = 0; t->joy1 = 0x30; settle(); check(t->trig == 2 && t->pump == 2, "P2 B1 + B2", t->trig, 2);
    t->joy1 = 0; settle();

    // crosshair
    t->rst = 1; settle(); t->rst = 0; settle();
    t->ana0 = ana(-128 + 0x40, -128 + 0x30); t->ana1 = ana(-128 + 0xc0, -128 + 0xd0); settle(); t->ana0 = 0; t->ana1 = 0;
    frame();
    check(frame().empty(), "crosshair off: no dots");
    for (int show = 1; show <= 3; show++) {
        t->show = show; frame();
        auto d = frame();
        int want = 0;
        for (int p = 0; p < 2; p++) {
            if (!(show >> p & 1)) continue;
            int vx = p ? 0xd0 : 0x30, vy = p ? 0xc0 : 0x40, cx = vx * 320 / 256, cy = vy * 240 / 256, col = p ? 0x20ff20 : 0xff2020;
            for (int k = 2; k <= 6; k++)
                for (auto xy : { std::make_pair(cx - k, cy), std::make_pair(cx + k, cy), std::make_pair(cx, cy - k), std::make_pair(cx, cy + k) }) {
                    bool seen = false;
                    for (auto& e : d) if (e.first == xy && e.second == col) seen = true;
                    check(seen, p ? "crosshair P2 dot" : "crosshair P1 dot", xy.first * 1000 + xy.second);
                }
            want += 20;
        }
        check((int)d.size() == want, "crosshair: dot count", d.size(), want);
    }
    // P1 over P2 where they meet
    t->ana1 = ana(-128 + 0x40, -128 + 0x30); settle(); t->ana1 = 0; frame();
    auto d = frame();
    bool green = false;
    for (auto& e : d) if (e.second == 0x20ff20) green = true;
    check(!green && d.size() == 20, "crosshairs on each other: P1's red", d.size(), 20);

    printf(fails ? "s2_guns: %d FAILED\n" : "s2_guns: all checks OK\n", fails);
    delete t;
    return fails ? 1 : 0;
}
