#!/usr/bin/env bash
# bench_mmap.sh -- is v1's fixed startup cost the 216MB reservation?
# Both probes are assembled by v1 itself and do exactly one mmap each.
cd "$(dirname "$0")/.."
V=${1:-./v1}
REPS=${2:-20}

$V tests/mmap_big.v0   /tmp/mm_big   || exit 1
$V tests/mmap_small.v0 /tmp/mm_small || exit 1

timeit() {
    local prog="$1" best="" t0 t1 d
    for _ in $(seq "$REPS"); do
        t0=$(date +%s%N); "$prog"; t1=$(date +%s%N)
        d=$(( (t1 - t0) / 1000 ))
        if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
    done
    echo "$best"
}

b=$(timeit /tmp/mm_big)
s=$(timeit /tmp/mm_small)
echo "mmap 216 MiB + exit : ${b} us"
echo "mmap   1 MiB + exit : ${s} us"
echo "=> cost of the big reservation: $(( b - s )) us"
rm -f /tmp/mm_big /tmp/mm_small
