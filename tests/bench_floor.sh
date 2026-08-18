#!/usr/bin/env bash
# bench_floor.sh -- measure the fixed per-invocation cost (startup, mmap,
# output write) independent of source size, by timing a near-empty input.
cd "$(dirname "$0")/.."
V=${1:-./v1}
REPS=${2:-20}

printf 'ret\n' > /tmp/floor.v0

best=""
for _ in $(seq "$REPS"); do
    t0=$(date +%s%N)
    $V /tmp/floor.v0 /tmp/floor.out
    t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000 ))
    if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
done
echo "v1 floor (1-line input, best of $REPS): ${best} us"

# compare against the cheapest possible process: /bin/true
best2=""
for _ in $(seq "$REPS"); do
    t0=$(date +%s%N)
    /bin/true
    t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000 ))
    if [ -z "$best2" ] || [ "$d" -lt "$best2" ]; then best2=$d; fi
done
echo "/bin/true      (bare process spawn):  ${best2} us"
echo "=> v1's own fixed cost above spawn:   $(( best - best2 )) us"
echo
ls -l /tmp/floor.out | awk '{print "output size for `ret`: " $5 " bytes"}'
rm -f /tmp/floor.v0 /tmp/floor.out
