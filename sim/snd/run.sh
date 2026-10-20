#!/bin/bash
# Sound bench (tb_x1.sv, tb_x1.cpp), in WSL:  sim/snd/run.sh <x1.log> <x1snd.bin> <seconds> <out.wav> [+alt] [+lat=N] [+native]
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="$HOME/build_seta2/snd"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 -CFLAGS "-O2" -Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
    --top-module tb_x1 -Mdir "$B/obj" ../../rtl/s2_cen.sv ../../modules/x1_010/x1_010.sv tb_x1.sv tb_x1.cpp \
    > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -20; exit 1; }
fi
"$B/obj/Vtb_x1" "$@"
