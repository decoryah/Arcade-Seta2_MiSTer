#!/bin/bash
# Runs the video bench (already built: NOBUILD) over every prepared frame of the given sets:
#   sim/video/corpus.sh <set>...      (IDEAL=1: the ideal-memory build)
WK="${WORK:-$(cd "$(dirname "$0")/../../.." && pwd)/work}"   # the scratch folder next to the repository (WORK= elsewhere)
W=$WK/states
cd "$(dirname "$0")"
for s in "$@"; do
  fr=$(ls $W/$s/*.plst | sed 's/.*f0*\([0-9][0-9]*\)\.plst/\1/' | tr '\n' ' ')
  echo "== $s"; mkdir -p $WK/vbpng/$s
  NOBUILD=1 bash run.sh "$W/$s" $fr +png=$WK/vbpng/$s
done
