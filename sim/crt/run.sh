#!/bin/bash
# Unit bench of the CRT Adjust glue + rmonic79's line buffer (tb_crtadj.cpp), in WSL: sim/crt/run.sh [DOT_DIV ...]   (default: 15 13 11, the three builds)
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
st=0
for dd in ${@:-15 13 11}; do
  B="${BDIR:-$HOME/build_seta2/crtadj}_$dd"; mkdir -p "$B"
  verilator --cc --exe --build -j 8 -O2 -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-INITIALDLY -Wno-PROCASSINIT -Wno-BLKSEQ -GDOT_DIV=$dd -CFLAGS "-O2 -DDOT_DIV=$dd" --top-module s2_crtadj -Mdir "$B/obj" \
    ../../modules/crt_adjust/crt_adjust.sv ../../rtl/s2_crtadj.sv tb_crtadj.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -20; exit 1; }
  grep -E "%Warning" "$B/build.log" | grep -v crt_adjust.sv | head -10
  "$B/obj/Vs2_crtadj" || st=1
done
exit $st
