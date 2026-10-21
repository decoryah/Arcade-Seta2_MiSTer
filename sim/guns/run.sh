#!/bin/bash
# Unit bench of the light guns' aim and crosshair (rtl/s2_guns.sv, tb_guns.cpp), in WSL: sim/guns/run.sh
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_seta2/guns}"; mkdir -p "$B"
verilator --cc --exe --build -j 8 -O2 -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ --top-module s2_guns -Mdir "$B/obj" ../../rtl/s2_guns.sv tb_guns.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -20; exit 1; }
grep -E "%Warning" "$B/build.log" | head -10
"$B/obj/Vs2_guns"
