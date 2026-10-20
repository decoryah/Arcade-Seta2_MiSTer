#!/bin/bash
# Machine bench of one set with its build's clocks (Seta2.sv): sim/sys/runb.sh <set> <frames> <outname> [bench args]
# Builds per clock set in $HOME/build_seta2/b_<build>$BSUF on first use; pictures into work/sys/<outname>/, log work/sys/<outname>.log.
S=$1; N=$2; O=$3; shift 3
case "$S" in
  grdians*)        B=grd; VF="-GCLK_HZ=93750000 -GDOT_DIV=15" ;;
  penbros|ablast)  B=pen; VF="-GCLK_HZ=91000000 -GDOT_DIV=13" ;;
  *)               B=main; VF="-GCLK_HZ=89458793 -GDOT_DIV=11" ;;
esac
W="${WORK:-$(cd "$(dirname "$0")/../../.." && pwd)/work}"   # the scratch folder next to the repository (WORK= elsewhere)
cd "$(dirname "$0")"
BD=$HOME/build_seta2/b_$B$BSUF                  # BSUF: a separate build (e.g. after an RTL change)
( flock 9; [ -x $BD/obj/Vtb_sys ] || VFLAGS="$VF" BDIR=$BD bash run.sh $W/images/$S.img 1 /tmp/b_$B$BSUF > /dev/null 2>&1 ) 9> /tmp/b_$B$BSUF.lock
rm -rf $W/sys/$O; mkdir -p $W/sys/$O
NOBUILD=1 BDIR=$BD bash run.sh $W/images/$S.img $N $W/sys/$O/f "$@" > $W/sys/$O.log 2>&1
