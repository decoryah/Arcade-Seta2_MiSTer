#!/bin/bash
# Whole-machine bench (tb_sys.sv, tb_sys.cpp), in WSL:
#   sim/sys/run.sh <image> <frames> <out-prefix> [+dsw1=HEX +dsw2=HEX +jumpers=HEX +dump=a,b +every=N +lat=N +inputs=F +wav +fastload
#                  +nvload=F +nvdump=F]
# The image is tools/seta2_image.py's.  Build directory: $HOME/build_seta2/sys (NOBUILD=1 reuses it); VFLAGS: more Verilator
# options, e.g. a build's clocks: VFLAGS="-GCLK_HZ=89458793 -GDOT_DIV=11" (Seta2), 93750000 / 15 (Seta2Grd), 91000000 / 13 (Seta2Pen).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_seta2/sys}"; mkdir -p "$B"
R=../../rtl; M=../../modules
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" ${THREADS:+--threads $THREADS} $VFLAGS \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-UNUSEDPARAM -Wno-IMPLICIT -Wno-CASEX -Wno-COMBDLY -Wno-SELRANGE -Wno-ASCRANGE -Wno-UNPACKED -Wno-GENUNNAMED \
    --top-module tb_sys -Mdir "$B/obj" \
    $R/s2_core.sv $R/s2_mem.sv $R/s2_main.sv $R/s2_tmp68301.sv $R/s2_video.sv $R/s2_render.sv $R/s2_dpram.sv $R/s2_sdram.sv $R/s2_cache.sv \
    $R/s2_cen.sv $R/s2_eeprom.sv $R/s2_samports.sv $R/s2_nvram.sv $M/x1_010/x1_010.sv $M/cpu-fx68k/fx68kAlu.sv $M/cpu-fx68k/uaddrPla.sv $M/cpu-fx68k/fx68k.sv \
    ../sdram_bl4_model.sv tb_sys.sv tb_sys.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp ../../microrom.mem ../../nanorom.mem "$B/"
IMG="$1"; shift
case "$IMG" in /*) ;; *) IMG="$PWD/$IMG" ;; esac
OUT="$2"; case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
N="$1"; shift 2
cd "$B"
./obj/Vtb_sys "$IMG" "$N" "$OUT" "$@"
