#!/usr/bin/env bash
# determinism.sh -- run the same parallel assembly repeatedly and confirm
# every run produces identical bytes, and that they match serial.
# A difference that varies run to run means a race; a stable difference
# means a plain logic bug. Telling those apart comes first.
cd "$(dirname "$0")/.."
V=${1:-./v1}
SRC=${2:-v1.v0}
J=${3:-4}
RUNS=${4:-6}

$V "$SRC" /tmp/dt_ser 1 || { echo "serial failed"; exit 1; }
prev=""
allsame=1
matchser=1
for ((i=0; i<RUNS; i++)); do
    $V "$SRC" "/tmp/dt_$i" "$J" || { echo "run $i failed"; exit 1; }
    if ! cmp -s /tmp/dt_ser "/tmp/dt_$i"; then
        matchser=0
        n=$(cmp -l /tmp/dt_ser "/tmp/dt_$i" | wc -l)
        echo "run $i: differs from serial in $n bytes"
    fi
    if [ -n "$prev" ] && ! cmp -s "$prev" "/tmp/dt_$i"; then allsame=0; fi
    prev="/tmp/dt_$i"
done

if [ $allsame -eq 1 ]; then
    echo "parallel runs are identical to each other (deterministic)"
else
    echo "PARALLEL RUNS DIFFER FROM EACH OTHER -- race condition"
fi
[ $matchser -eq 1 ] && echo "and identical to serial" || echo "but NOT equal to serial"
rm -f /tmp/dt_ser /tmp/dt_*

# Exit status, not just a message: this script reported a race in words
# and returned 0 regardless, so run_all.sh could not have noticed one.
[ $allsame -eq 1 ] && [ $matchser -eq 1 ]
