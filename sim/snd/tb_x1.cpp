// Sound bench driver: replays MAME's X1-010 writes (tools/lua/x1log.lua) at their times, answers the sample reads from the x1snd
// region through the bank registers as s2_core does (page = bank % pages), writes the mixed output (L + R, as MAME's mono speaker)
// at 48 kHz.
//
//   Vtb_x1 <x1.log> <x1snd.bin> <seconds> <out.wav> [+alt] [+lat=N] [+native]
//   +native: one WAV sample per X1-010 sample (clock / 512) instead of 48 kHz
//   +sync:   each write held until the end of the chip's current pass over the channels (a window shortly before the next
//            strobe), so it takes effect from the next sample on
//   +alog=F: (with +sync) the sample each write takes effect from, one line per write, for tools/x1_model.py --applied F
#include "Vtb_x1.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>
#include <deque>

struct Ev { double t; char kind; int a, d, m; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s <x1.log> <x1snd.bin> <seconds> <out.wav> [+alt] [+lat=N] [+native]\n", argv[0]); return 2; }
    std::vector<Ev> ev;
    {
        FILE *f = fopen(argv[1], "r");
        if (!f) return 2;
        char line[256];
        while (fgets(line, sizeof line, f)) {
            for (char *p = line; *p; p++) if (*p == ',') *p = '.';
            Ev e{}; char k;
            if (sscanf(line, "%lf %c", &e.t, &k) != 2) continue;
            e.kind = k;
            if (k == 'x') sscanf(line, "%lf %c %x %x %x", &e.t, &k, &e.a, &e.d, &e.m);
            else sscanf(line, "%lf %c %d %x", &e.t, &k, &e.a, &e.d);
            ev.push_back(e);
        }
        fclose(f);
    }
    std::vector<uint8_t> rom;
    {
        FILE *f = fopen(argv[2], "rb");
        fseek(f, 0, SEEK_END); rom.resize(ftell(f)); fseek(f, 0, SEEK_SET);
        if (fread(rom.data(), 1, rom.size(), f) != rom.size()) return 2;
        fclose(f);
    }
    double secs = atof(argv[3]);
    bool alt = false, native = false, sync = false;
    FILE *alog = nullptr;
    int lat = 20;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "+alt")) alt = true;
        else if (!strcmp(argv[i], "+native")) native = true;
        else if (!strncmp(argv[i], "+lat=", 5)) lat = atoi(argv[i] + 5);
        else if (!strcmp(argv[i], "+sync")) sync = true;
        else if (!strncmp(argv[i], "+alog=", 6)) alog = fopen(argv[i] + 6, "w");
    }
    int pages = rom.size() / 0x20000;
    uint8_t bank[8] = {0};

    Vtb_x1 *top = new Vtb_x1;
    top->alt = alt;
    top->rst = 1;
    uint64_t cyc = 0;
    auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; };
    for (int i = 0; i < 16; i++) tick();
    top->rst = 0;

    std::vector<int16_t> out;
    size_t ei = 0;
    const double CLK = 96e6;
    uint64_t end = (uint64_t)(secs * CLK);
    uint64_t next = 0;
    std::deque<std::pair<uint64_t, uint32_t>> rq;
    int pend_rom = 0;
    // +sync: a sample is 512 chip clocks = 96e6 * 512 / clock clocks; the window is the last ~200 clocks before the next strobe
    const double per = 96e6 * 512 / (alt ? 32530470.0 / 2 : 50e6 / 3);
    uint64_t last_stb = 0, last_wr = 0;
    while (cyc < end) {
        top->x_req = 0;
        // the next write due (one per clock)
        bool open = !sync || (last_stb && cyc >= last_stb + (uint64_t)per - 200 && cyc < last_stb + (uint64_t)per - 20);
        if (open && ei < ev.size() && (uint64_t)(ev[ei].t * CLK) <= cyc && cyc >= last_wr + 4) {
            last_wr = cyc;                    // (a 68000 bus cycle apart at least, as in the core)
            if (alog) fprintf(alog, "%zu\n", out.size() + 2);   // (the write is in before the pass for out[size + 1], whose
                                                                 // samples come out a strobe later: out[size + 2] here)
            const Ev &e = ev[ei++];
            if (e.kind == 'x') {
                top->x_req = 1; top->x_addr = e.a & 0x1fff; top->x_din = e.d;
                top->x_uds = (e.m >> 8) != 0; top->x_lds = (e.m & 0xff) != 0;
            } else bank[e.a & 7] = e.d;
        }
        // the sample ROM, through the banks
        top->rom_valid = 0;
        if (!rq.empty() && rq.front().first <= cyc) {
            uint32_t a = rq.front().second; rq.pop_front();
            uint32_t page = bank[(a >> 17) & 7] % pages;
            top->rom_data = rom[(size_t)page * 0x20000 + (a & 0x1ffff)];
            top->rom_valid = 1;
        }
        tick();
        if (top->rom_req) rq.push_back({cyc + lat, top->rom_addr});
        if (top->stb) last_stb = cyc;
        if (native) { if (top->stb) out.push_back(top->audio); }
        else if (cyc >= next) { out.push_back(top->audio); next += 2000; }
    }
    FILE *f = fopen(argv[4], "wb");
    uint32_t rate = native ? (uint32_t)((alt ? 32530470.0 / 2 : 50e6 / 3) / 512 + 0.5) : 48000;
    uint32_t bytes = out.size() * 2, v;
    uint16_t s;
    fwrite("RIFF", 1, 4, f); v = 36 + bytes; fwrite(&v, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    v = 16; fwrite(&v, 4, 1, f); s = 1; fwrite(&s, 2, 1, f); s = 1; fwrite(&s, 2, 1, f);
    fwrite(&rate, 4, 1, f); v = rate * 2; fwrite(&v, 4, 1, f); s = 2; fwrite(&s, 2, 1, f); s = 16; fwrite(&s, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f);
    fwrite(out.data(), 2, out.size(), f);
    fclose(f);
    printf("%zu samples, %zu writes replayed\n", out.size(), ei);
    delete top;
    return 0;
}
