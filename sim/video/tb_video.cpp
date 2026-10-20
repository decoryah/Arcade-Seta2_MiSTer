// Frozen-state bench of the seta2 video chip (tb_video.sv): loads MAME states (tools/capture.py + tools/vbench_prep.py) through
// the back door, runs the chip from reset until it has shown one frame, and compares that frame with the pixels MAME drew.
//
//   Vtb_video <statedir> <frame> [<frame> ...] [+png=<dir>] [+lat=N] [+rdly=N] [+late]
//
// statedir holds f<N>.spr / .pal1 / .vr / .plst / .rgb / .txt and bench.cfg (the set's video configuration and its video.bin).
// Graphics: the real SDRAM path (s2_sdram + sdram_bl4_model), or with an IDEAL_GFX build an in-order memory of latency +lat.
// Prints per frame: differing pixels, overruns, the slowest line in clocks and its tile rows.  Exit 1 if any frame differs.
#include "Vtb_video.h"
#include "Vtb_video___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <map>

static std::string winpath(std::string p) {
    // C:\a\b -> /mnt/c/a/b
    if (p.size() > 2 && p[1] == ':') {
        std::string r = "/mnt/";
        r += (char)tolower(p[0]);
        for (size_t i = 2; i < p.size(); i++) r += (p[i] == '\\') ? '/' : p[i];
        return r;
    }
    return p;
}

static std::vector<uint8_t> slurp(const std::string &p) {
    std::vector<uint8_t> v;
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize(n);
    if (n && fread(v.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", p.c_str()); exit(2); }
    fclose(f);
    return v;
}

static Vtb_video *top;
static uint64_t cyc = 0;
static std::vector<uint8_t> rom;
static int lat = 12;
static std::deque<std::pair<uint64_t, uint32_t>> gq;   // ideal memory: (due cycle, unit address)

static void tick() {
    top->clk = 0; top->eval();
#ifdef IDEAL_GFX
    // requests accepted on this edge (x_ready is always 1)
    bool take = top->gf_req;
    uint32_t a = top->gf_addr;
    top->x_valid = 0;
    if (!gq.empty() && gq.front().first <= cyc) {
        uint32_t u = gq.front().second; gq.pop_front();
        uint64_t d = 0;
        for (int q = 0; q < 8; q++) {
            uint64_t byte = ((size_t)u * 8 + q < rom.size()) ? rom[(size_t)u * 8 + q] : 0;
            d |= byte << (8 * q);
        }
        top->x_valid = 1; top->x_data = d;
    }
    if (take) gq.push_back({cyc + lat, a});
#endif
    top->clk = 1; top->eval();
    cyc++;
}

static void bd(int sel, int addr, uint64_t data) {
    top->bd_we = 1; top->bd_sel = sel; top->bd_addr = addr; top->bd_data = data;
    tick();
    top->bd_we = 0;
}

static void write_ppm(const std::string &p, int w, int h, const std::vector<uint8_t> &rgb) {
    FILE *f = fopen(p.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s <statedir> <frame>... [+png=dir] [+lat=N] [+rdly=N] [+late]\n", argv[0]); return 2; }
    std::string sdir = winpath(argv[1]);
    std::vector<int> frames;
    std::string pngdir;
    int rdly = 144;
    bool late = false;
    for (int i = 2; i < argc; i++) {
        if (!strncmp(argv[i], "+png=", 5)) pngdir = argv[i] + 5;
        else if (!strncmp(argv[i], "+lat=", 5)) lat = atoi(argv[i] + 5);
        else if (!strncmp(argv[i], "+rdly=", 6)) rdly = atoi(argv[i] + 6);
        else if (!strcmp(argv[i], "+late")) late = true;
        else if (argv[i][0] != '+') frames.push_back(atoi(argv[i]));
    }

    // the set's configuration
    std::map<std::string, std::string> cfg;
    {
        FILE *f = fopen((sdir + "/bench.cfg").c_str(), "r");
        if (!f) { fprintf(stderr, "no bench.cfg in %s (tools/vbench_prep.py)\n", sdir.c_str()); return 2; }
        char line[1024];
        while (fgets(line, sizeof line, f)) {
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = 0;
            std::string v = eq + 1;
            while (!v.empty() && (v.back() == '\n' || v.back() == '\r')) v.pop_back();
            cfg[line] = v;
        }
        fclose(f);
    }
    auto ci = [&](const char *k) { return (uint32_t)strtoul(cfg[k].c_str(), nullptr, 0); };

    top = new Vtb_video;
    top->dot_inc = ci("dot_inc");
    top->h_total = ci("h_total"); top->h_sync = ci("h_sync"); top->h_start = ci("h_start"); top->h_width = ci("h_width");
    top->v_total = ci("v_total"); top->v_sync = ci("v_sync"); top->v_start = ci("v_start"); top->v_height = ci("v_height");
    top->tile_mask = ci("tile_mask"); top->tile_count = ci("tile_count");
    top->rdly = rdly;
    top->rd_late = late;
    top->x_ready = 1;
    const int W = ci("h_width"), H = ci("v_height");

    rom = slurp(winpath(cfg["video"]));
#ifndef IDEAL_GFX
    // the graphics ROM into the SDRAM model: byte address A -> bank A[7:6], row A[24:12], column {A[11:8], A[5:3], A[2:1]}
    {
        auto &mem = top->rootp->tb_video__DOT__u_chip__DOT__mem;
        for (size_t a = 0; a + 1 < rom.size(); a += 2) {
            uint32_t bank = (a >> 6) & 3, row = (a >> 12) & 0x1fff, col = (((a >> 8) & 15) << 5) | (((a >> 3) & 7) << 2) | ((a >> 1) & 3);
            uint32_t w = (bank << 22) | (row << 9) | col;
            mem[w] = rom[a] | (rom[a + 1] << 8);
        }
    }
#endif

    // SDRAM start-up
    top->rst = 1; top->sd_init = 1;
    for (int i = 0; i < 8; i++) tick();
    top->sd_init = 0;
    while (!top->sd_ready) tick();

    int bad_frames = 0;
    for (int fr : frames) {
        char pre[64];
        snprintf(pre, sizeof pre, "/f%05d", fr);
        std::string P = sdir + pre;
        auto spr = slurp(P + ".spr"), pal = slurp(P + ".pal1"), vr = slurp(P + ".vr"), pl = slurp(P + ".plst"),
             mame = slurp(P + ".rgb");
        // load through the back door, the chip held in reset
        top->rst = 1;
        for (int i = 0; i < 32768; i++) { uint64_t d; memcpy(&d, &spr[i * 8], 8); bd(0, i, d); }
        for (int i = 0; i < 32768; i++) bd(1, i, pal[i * 2] | (pal[i * 2 + 1] << 8));
        for (int i = 0; i < 512; i++) { uint64_t d; memcpy(&d, &pl[i * 8], 8); bd(2, i, d); }
        for (int i = 0; i < 32; i++) bd(3, i, vr[i * 2] | (vr[i * 2 + 1] << 8));
        for (int i = 0; i < 4; i++) tick();
        top->rst = 0;

        // run until one whole frame has been shown
        std::vector<uint8_t> pic(W * H * 3, 0);
        int x = 0, y = -1, prev_hb = 1, prev_vb = 1, frames_seen = 0, overruns = 0;
        unsigned max_cyc = 0, max_rows = 0, lines = 0;
        bool active_seen = false;
        uint64_t limit = cyc + 4000000;
        while (cyc < limit) {
            if (top->ce_pix) {
                int hb = top->hblank, vb = top->vblank;
                if (prev_vb && !vb) { y = -1; active_seen = true; }
                if (!vb && prev_hb && !hb) { y++; x = 0; }
                if (!vb && !hb && active_seen && y >= 0 && y < H && x < W) {
                    pic[(y * W + x) * 3 + 0] = top->r; pic[(y * W + x) * 3 + 1] = top->g; pic[(y * W + x) * 3 + 2] = top->b;
                    x++;
                }
                if (!prev_vb && vb && active_seen) { frames_seen++; break; }
                prev_hb = hb; prev_vb = vb;
            }
            if (top->dbg_overrun) overruns++;
            if (top->dbg_line_done) {
                lines++;
                if (top->dbg_line_cycles > max_cyc) max_cyc = top->dbg_line_cycles;
                if (top->dbg_line_rows > max_rows) max_rows = top->dbg_line_rows;
            }
            tick();
        }
        int diff = 0;
        for (int i = 0; i < W * H; i++)
            if (memcmp(&pic[i * 3], &mame[i * 3], 3)) diff++;
        int sderr = 0;
#ifndef IDEAL_GFX
        sderr = top->rootp->tb_video__DOT__u_chip__DOT__errors;
#endif
        printf("frame %5d: %6d differing pixels  (%s, %u lines, slowest %u clocks / %u rows, overruns %d, sdram errors %d)\n",
               fr, diff, frames_seen ? "shown" : "NOT SHOWN", lines, max_cyc, max_rows, overruns, sderr);
        fflush(stdout);
        if (diff || !frames_seen) {
            bad_frames++;
            if (!pngdir.empty()) {
                char n[512];
                snprintf(n, sizeof n, "%s/rtl_%05d.ppm", pngdir.c_str(), fr); write_ppm(n, W, H, pic);
                snprintf(n, sizeof n, "%s/mame_%05d.ppm", pngdir.c_str(), fr); write_ppm(n, W, H, mame);
            }
        }
    }
    delete top;
    return bad_frames ? 1 : 0;
}
