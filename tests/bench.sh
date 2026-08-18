#!/usr/bin/env bash
# bench.sh -- throughput benchmark. Usage: bench.sh [assembler] [reps]
#
# Times assembly of generated sources at several sizes and reports MB/s
# and lines/s. Each size is run REPS times and the BEST wall time is
# kept: the fastest run is the one least polluted by scheduler noise,
# and we care about the assembler's own cost, not the machine's mood.
cd "$(dirname "$0")/.."
V=${1:-./v1}
REPS=${2:-5}

bench_one() {
    local label="$1" src="$2"
    local bytes lines best ms
    bytes=$(wc -c < "$src")
    lines=$(wc -l < "$src")
    best=""
    for _ in $(seq "$REPS"); do
        local t0 t1 d
        t0=$(date +%s%N)
        $V "$src" /tmp/bench.out || { echo "$label: ASSEMBLY FAILED"; return 1; }
        t1=$(date +%s%N)
        d=$(( (t1 - t0) / 1000 ))          # microseconds
        if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
    done
    # integer math only: MB/s = bytes / usec  (since 1 B/us == 1 MB/s)
    local mbps=$(( bytes / (best > 0 ? best : 1) ))
    local frac=$(( (bytes * 10 / (best > 0 ? best : 1)) % 10 ))
    local lps=$(( lines * 1000000 / (best > 0 ? best : 1) ))
    ms=$(( best / 1000 ))
    printf '%-14s %8s lines %9s B  %5s.%s ms  %4s.%s MB/s  %s lines/s\n' \
        "$label" "$lines" "$bytes" "$ms" "$(( (best % 1000) / 100 ))" \
        "$mbps" "$frac" "$lps"
    rm -f /tmp/bench.out
}

echo "assembler: $V   best-of-$REPS"
echo

tests/gen_big.sh 1000   > /tmp/bench_10k.v0
tests/gen_big.sh 10000  > /tmp/bench_100k.v0
tests/gen_big.sh 100000 > /tmp/bench_1m.v0

bench_one "10k lines"  /tmp/bench_10k.v0
bench_one "100k lines" /tmp/bench_100k.v0
bench_one "1M lines"   /tmp/bench_1m.v0

echo
echo "self-host (v1.v0):"
bench_one "v1.v0" v1.v0

rm -f /tmp/bench_10k.v0 /tmp/bench_100k.v0 /tmp/bench_1m.v0
