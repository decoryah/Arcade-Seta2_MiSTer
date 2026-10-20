#!/bin/bash
# Verilator lint of the core's modules (in WSL): sim/lint.sh [top]
cd "$(dirname "$0")/.."
export PATH=$HOME/tools/oss-cad-suite/bin:$PATH
for top in ${1:-s2_core s2_mem}; do
echo "== $top"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND \
  -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-GENUNNAMED -Wno-VARHIDDEN --no-assert-case -Wno-BLKANDNBLK -Wno-TIMESCALEMOD \
  -Wno-SYNCASYNCNET -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNSIGNED -Wno-CMPCONST -Wno-ASCRANGE -Wno-PROCASSINIT -Wno-CASEX -Wno-WIDTH \
  -Wno-BLKSEQ -Wno-IMPLICIT \
  --top-module $top rtl/s2_core.sv rtl/s2_mem.sv rtl/s2_main.sv rtl/s2_tmp68301.sv rtl/s2_video.sv rtl/s2_render.sv rtl/s2_dpram.sv rtl/s2_sdram.sv \
  rtl/s2_cache.sv rtl/s2_cen.sv rtl/s2_eeprom.sv modules/x1_010/x1_010.sv modules/cpu-fx68k/fx68kAlu.sv modules/cpu-fx68k/uaddrPla.sv \
  modules/cpu-fx68k/fx68k.sv 2>&1 | grep -v "^ " | grep -v "fx68k" | head -60
done
