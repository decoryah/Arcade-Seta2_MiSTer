#!/bin/bash
# Boot check of one set in the machine bench (in WSL): sim/sys/boot.sh <set> <frames> [bench args]
# Pictures every 10 frames into work/sys/<set>/, log work/sys/<set>.log.  Uses the build in $HOME/build_seta2/sys2.
S=$1; N=$2; shift 2
W="${WORK:-$(cd "$(dirname "$0")/../../.." && pwd)/work}"   # the scratch folder next to the repository (WORK= elsewhere)
mkdir -p $W/sys/$S
cd "$(dirname "$0")"
NOBUILD=1 BDIR=$HOME/build_seta2/sys2 bash run.sh $W/images/$S.img $N $W/sys/$S/f +every=10 "$@" > $W/sys/$S.log 2>&1
