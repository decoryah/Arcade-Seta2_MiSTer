// Whole-machine bench of the seta2 core (tb_sys.sv): boots a set from its image (tools/seta2_image.py), runs N frames, writes the
// pictures (PPM) and the sound (WAV).
//
//   Vtb_sys <image> <frames> <out-prefix> [+dsw1=HEX] [+dsw2=HEX] [+jumpers=HEX] [+dump=a,b,c] [+every=N] [+lat=N]
//           [+inputs=FILE] [+wav] [+fastload] [+stream] [+rdly=N] [+latj=N] [+busy=P] [+gap=P]
//
// The image's header goes through the loader's byte port; the program / samples go into the DDR3 model and the graphics into the
// SDRAM model directly (+fastload: the real fast-load path, the header and graphics copied by s2_mem from the DDR3; +stream: the
// whole image through the byte port, as an ordinary download; both check what landed where).
// Frames are counted at the start of each vertical blank; frame N's picture is the one shown before vblank N.
// +inputs: lines "frame joy1 joy2" (hex, Seta2.sv's joystick bits), each holding from that frame on.
#include "Vtb_sys.h"
#include "Vtb_sys___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <set>
#include <map>

static Vtb_sys *top;
static uint64_t cyc = 0;
static std::vector<uint8_t> ddr;                 // DDR3 from byte 0x30000000
static const uint32_t DDR_BASE_BEAT = 0x6000000;
static int lat = 24;
// +latj=N: up to N more clocks per read, random (in order); +busy=P: DDRAM_BUSY on P % of the clocks; +gap=P: no beat on P % of
// the clocks a beat could come (the real DDR3 is shared with the HPS and the scaler)
static int latj = 0, busy_pct = 0, gap_pct = 0;
static uint32_t rs_ = 0x2545F491u;
static uint32_t rnd() { rs_ ^= rs_ << 13; rs_ ^= rs_ >> 17; rs_ ^= rs_ << 5; return rs_; }
static uint64_t last_due = 0;
struct Rd { uint64_t due; uint32_t beat; int n; };
static std::deque<Rd> rq;
static uint64_t ddr_reads = 0, ddr_writes = 0;

static std::vector<uint8_t> slurp(const char *p) {
    std::vector<uint8_t> v;
    FILE *f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) exit(2);
    fclose(f);
    return v;
}

static void tick() {
    top->clk = 0; top->eval();
    // DDR3 (Avalon): accepted on this edge when RD / WE and not BUSY
    bool busy = busy_pct && (int)(rnd() % 100) < busy_pct;
    top->DDRAM_BUSY = busy;
    top->DDRAM_DOUT_READY = 0;
    if (!rq.empty() && rq.front().due <= cyc && !(gap_pct && (int)(rnd() % 100) < gap_pct)) {
        Rd &r = rq.front();
        size_t o = (size_t)(r.beat - DDR_BASE_BEAT) * 8;
        uint64_t d = 0;
        for (int k = 0; k < 8; k++) d |= (uint64_t)((o + k < ddr.size()) ? ddr[o + k] : 0) << (8 * k);
        top->DDRAM_DOUT = d; top->DDRAM_DOUT_READY = 1;
        r.beat++; r.due = cyc + 1;
        if (--r.n == 0) rq.pop_front();
    }
    if (top->DDRAM_RD && !busy) {
        uint64_t due = cyc + lat + (latj ? rnd() % (latj + 1) : 0);
        if (due < last_due) due = last_due;
        last_due = due;
        rq.push_back({due, (uint32_t)top->DDRAM_ADDR, (int)top->DDRAM_BURSTCNT});
        ddr_reads++;
    }
    if (top->DDRAM_WE && !busy) {
        size_t o = (size_t)((uint32_t)top->DDRAM_ADDR - DDR_BASE_BEAT) * 8;
        for (int k = 0; k < 8; k++)
            if ((top->DDRAM_BE >> k) & 1) { if (o + k < ddr.size()) ddr[o + k] = (top->DDRAM_DIN >> (8 * k)) & 0xff; }
        ddr_writes++;
    }
    top->clk = 1; top->eval();
    cyc++;
}

static void write_ppm(const std::string &p, int w, int h, const std::vector<uint8_t> &rgb) {
    FILE *f = fopen(p.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb.data(), 1, rgb.size(), f);
    fclose(f);
}

static void wav_header(FILE *f, uint32_t n, uint32_t rate) {
    uint32_t bytes = n * 2;
    fwrite("RIFF", 1, 4, f); uint32_t v = 36 + bytes; fwrite(&v, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    v = 16; fwrite(&v, 4, 1, f); uint16_t s = 1; fwrite(&s, 2, 1, f); s = 1; fwrite(&s, 2, 1, f);
    fwrite(&rate, 4, 1, f); v = rate * 2; fwrite(&v, 4, 1, f); s = 2; fwrite(&s, 2, 1, f); s = 16; fwrite(&s, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <image> <frames> <out-prefix> [+...]\n", argv[0]); return 2; }
    const char *imgp = argv[1];
    int nframes = atoi(argv[2]);
    std::string out = argv[3];
    int dsw1 = 0xff, dsw2 = 0xff, jumpers = 0xff, every = 0, rdly = 144;
    bool wav = false, fastload = false, stream = false;
    std::set<int> dump;
    std::map<int, std::pair<int, int>> script;
    for (int i = 4; i < argc; i++) {
        std::string a = argv[i];
        if (!a.compare(0, 6, "+dsw1=")) dsw1 = strtol(a.c_str() + 6, nullptr, 16);
        else if (!a.compare(0, 6, "+dsw2=")) dsw2 = strtol(a.c_str() + 6, nullptr, 16);
        else if (!a.compare(0, 9, "+jumpers=")) jumpers = strtol(a.c_str() + 9, nullptr, 16);
        else if (!a.compare(0, 7, "+every=")) every = atoi(a.c_str() + 7);
        else if (!a.compare(0, 5, "+lat=")) lat = atoi(a.c_str() + 5);
        else if (!a.compare(0, 6, "+latj=")) latj = atoi(a.c_str() + 6);
        else if (!a.compare(0, 6, "+busy=")) busy_pct = atoi(a.c_str() + 6);
        else if (!a.compare(0, 5, "+gap=")) gap_pct = atoi(a.c_str() + 5);
        else if (!a.compare(0, 6, "+rdly=")) rdly = atoi(a.c_str() + 6);
        else if (a == "+wav") wav = true;
        else if (a == "+fastload") fastload = true;
        else if (a == "+stream") stream = true;
        else if (!a.compare(0, 6, "+dump=")) {
            std::string l = a.substr(6);
            size_t p = 0;
            while (p < l.size()) { size_t q = l.find(',', p); if (q == std::string::npos) q = l.size(); dump.insert(atoi(l.substr(p, q - p).c_str())); p = q + 1; }
        } else if (!a.compare(0, 8, "+inputs=")) {
            FILE *f = fopen(a.c_str() + 8, "r");
            if (!f) { fprintf(stderr, "no inputs file\n"); return 2; }
            int fr; unsigned j1, j2;
            while (fscanf(f, "%d %x %x", &fr, &j1, &j2) == 3) script[fr] = {(int)j1, (int)j2};
            fclose(f);
        }
    }

    auto img = slurp(imgp);
    ddr.assign(0x3100000, 0);
    if (!stream) memcpy(ddr.data(), img.data(), std::min(img.size(), ddr.size()));   // (+stream: the loader must write it)

    top = new Vtb_sys;
    top->dsw1 = dsw1; top->dsw2 = dsw2; top->jumpers = jumpers; top->rdly = rdly;
    top->joy1 = 0; top->joy2 = 0; top->pause = 0;
    top->mc_rst_in = 1; top->sd_init = 1;
    for (int i = 0; i < 8; i++) tick();
    top->sd_init = 0;
    while (!top->sd_ready) tick();

    if (fastload) {
        // the real path: the header and the graphics come from the DDR3
        top->fl_len = img.size(); top->fl_go = 1; tick(); top->fl_go = 0;
        while (!top->fl_busy) tick();
        uint64_t t0 = cyc;
        while (top->fl_busy || top->dl_busy) tick();
        printf("fast load: %llu clocks\n", (unsigned long long)(cyc - t0));
        // what it must have done: the header and the EEPROM image in s2_mem, every graphics word in the SDRAM chip
        int bad_hdr = 0, bad_ee = 0;
        for (int i = 0; i < 64; i++) if (top->rootp->tb_sys__DOT__u_mem__DOT__cfg_r[i] != img[i]) bad_hdr++;
        for (int i = 0; i < 128; i++) if (top->rootp->tb_sys__DOT__u_mem__DOT__ee_r[i] != img[0x100 + i]) bad_ee++;
        auto &mem = top->rootp->tb_sys__DOT__u_chip__DOT__mem;
        const size_t V = 0x900000;
        size_t bad_gfx = 0;
        for (size_t a = 0; a + 1 < img.size() - V; a += 2) {
            uint32_t bank = (a >> 6) & 3, row = (a >> 12) & 0x1fff, col = (((a >> 8) & 15) << 5) | (((a >> 3) & 7) << 2) | ((a >> 1) & 3);
            if (mem[(bank << 22) | (row << 9) | col] != (uint16_t)(img[V + a] | (img[V + a + 1] << 8))) bad_gfx++;
        }
        printf("fast load check: %d of 64 header bytes, %d of 128 EEPROM bytes, %zu of %zu graphics words differ\n",
               bad_hdr, bad_ee, bad_gfx, (img.size() - V) / 2);
        fflush(stdout);
    } else if (stream) {
        // an ordinary download: every byte of the image through the loader's byte port, held off by dl_wait as hps_io does
        uint64_t t0 = cyc;
        for (size_t a = 0; a < img.size(); a++) {
            while (top->dl_wait) tick();
            top->dl_we = 1; top->dl_addr = a; top->dl_data = img[a]; tick();
            top->dl_we = 0; tick(); tick();
        }
        while (top->dl_busy) tick();
        printf("stream load: %llu clocks\n", (unsigned long long)(cyc - t0));
        int bad_hdr = 0;
        for (int i = 0; i < 64; i++) if (top->rootp->tb_sys__DOT__u_mem__DOT__cfg_r[i] != img[i]) bad_hdr++;
        size_t bad_ddr = 0;
        for (size_t a = 0x100000; a < 0x900000 && a < img.size(); a++) if (ddr[a] != img[a]) bad_ddr++;
        auto &mem = top->rootp->tb_sys__DOT__u_chip__DOT__mem;
        const size_t V = 0x900000;
        size_t bad_gfx = 0;
        for (size_t a = 0; a + 1 < img.size() - V; a += 2) {
            uint32_t bank = (a >> 6) & 3, row = (a >> 12) & 0x1fff, col = (((a >> 8) & 15) << 5) | (((a >> 3) & 7) << 2) | ((a >> 1) & 3);
            if (mem[(bank << 22) | (row << 9) | col] != (uint16_t)(img[V + a] | (img[V + a + 1] << 8))) bad_gfx++;
        }
        printf("stream load check: %d of 64 header bytes, %zu of 8 MB program / sample bytes in the DDR3, %zu graphics words differ\n",
               bad_hdr, bad_ddr, bad_gfx);
        fflush(stdout);
    } else {
        // the header through the loader's byte port, then the graphics into the SDRAM model
        for (int a = 0; a < 0x1000; a++) {
            top->dl_we = 1; top->dl_addr = a; top->dl_data = img[a]; tick();
            top->dl_we = 0; tick();
        }
        auto &mem = top->rootp->tb_sys__DOT__u_chip__DOT__mem;
        const size_t V = 0x900000;
        for (size_t a = 0; a + 1 < img.size() - V; a += 2) {
            uint32_t bank = (a >> 6) & 3, row = (a >> 12) & 0x1fff, col = (((a >> 8) & 15) << 5) | (((a >> 3) & 7) << 2) | ((a >> 1) & 3);
            mem[(bank << 22) | (row << 9) | col] = img[V + a] | (img[V + a + 1] << 8);
        }
    }
    for (int i = 0; i < 16; i++) tick();
    top->mc_rst_in = 0;

    const int W = img[14] | (img[15] << 8), H = img[22] | (img[23] << 8);
    std::vector<uint8_t> pic(W * H * 3, 0);
    int frame = 0, x = 0, y = -1, prev_hb = 1, prev_vb = 1, overruns = 0;
    std::vector<int16_t> snd;
    uint64_t next_snd = cyc;
    FILE *trace = nullptr;
    printf("running %d frames of %dx%d\n", nframes, W, H);
    fflush(stdout);
    while (frame < nframes) {
        auto it = script.find(frame);
        if (it != script.end()) { top->joy1 = it->second.first; top->joy2 = it->second.second; }
        if (top->ce_pix) {
            int hb = top->hblank, vb = top->vblank;
            if (prev_vb && !vb) y = -1;
            if (!vb && prev_hb && !hb) { y++; x = 0; }
            if (!vb && !hb && y >= 0 && y < H && x < W) {
                pic[(y * W + x) * 3] = top->r; pic[(y * W + x) * 3 + 1] = top->g; pic[(y * W + x) * 3 + 2] = top->b;
                x++;
            }
            if (!prev_vb && vb) {
                frame++;
                if (dump.count(frame) || (every && frame % every == 0)) {
                    char n[64]; snprintf(n, sizeof n, ".f%05d.ppm", frame);
                    write_ppm(out + n, W, H, pic);
                }
                if (frame % 50 == 0) {
                    printf("frame %d (cycle %llu, ddr reads %llu, overruns %d, halted %d)\n", frame, (unsigned long long)cyc,
                           (unsigned long long)ddr_reads, overruns, top->cpu_halted);
                    fflush(stdout);
                }
            }
            prev_hb = hb; prev_vb = vb;
        }
        if (top->dbg_overrun) overruns++;
        if (wav && cyc >= next_snd) { snd.push_back(top->audio); next_snd += 2000; }     // 48 kHz
        tick();
    }
    if (wav) {
        FILE *f = fopen((out + ".wav").c_str(), "wb");
        wav_header(f, snd.size(), 48000);
        fwrite(snd.data(), 2, snd.size(), f);
        fclose(f);
    }
    int sderr = top->rootp->tb_sys__DOT__u_chip__DOT__errors;
    printf("done: %d frames, %llu cycles, overruns %d, sdram errors %d\n", frame, (unsigned long long)cyc, overruns, sderr);
    delete top;
    return 0;
}
