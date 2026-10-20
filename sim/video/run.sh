#!/bin/bash
# Frozen-state bench of the video chip (tb_video.sv, tb_video.cpp), in WSL:
#   sim/video/run.sh <statedir (Windows or WSL path)> <frame>... [+png=<dir>] [+lat=N] [+rdly=N] [+late]
# IDEAL=1 builds the variant with an ideal in-order graphics memory instead of s2_sdram + the SDRAM model.
# Build directory: $HOME/build_seta2/video[_ideal] (NOBUILD=1 reuses it).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
if [ -n "$IDEAL" ]; then B="$HOME/build_seta2/video_ideal"; DEF="-DIDEAL_GFX"; else B="$HOME/build_seta2/video"; DEF=""; fi
mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O2 $DEF" $DEF --public-flat-rw \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-UNUSEDPARAM -Wno-IMPLICIT -Wno-CASEX -Wno-COMBDLY -Wno-SELRANGE -Wno-ASCRANGE -Wno-UNPACKED -Wno-GENUNNAMED \
    --top-module tb_video -Mdir "$B/obj" \
    ../../rtl/s2_dpram.sv ../../rtl/s2_render.sv ../../rtl/s2_video.sv ../../rtl/s2_sdram.sv ../sdram_bl4_model.sv tb_video.sv tb_video.cpp \
    > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vtb_video" "$@"
