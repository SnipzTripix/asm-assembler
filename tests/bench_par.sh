#!/usr/bin/env bash
# bench_par.sh -- speedup from parallel assembly. Usage: bench_par.sh [asm] [reps]
# Reports best-of-REPS wall time per worker count, plus the speedup over
# -j1. Best-of is used deliberately: the fastest run is the one least
# polluted by scheduler noise, and noise hurts the parallel runs more
# (they need N cores free at once).
cd "$(dirname "$0")/.."
V=${1:-./v1}
REPS=${2:-5}

run_size() {
    local label="$1" src="$2"
    local base=""
    echo "--- $label ($(wc -l < "$src") lines, $(wc -c < "$src") B) ---"
    for j in 1 2 4 8 16; do
        local best="" t0 t1 d
        for _ in $(seq "$REPS"); do
            t0=$(date +%s%N)
            # output to /dev/null: writing megabytes to the WSL filesystem
            # varies by 100ms+ run to run and would swamp what is being
            # measured here, which is assembly throughput
            $V "$src" /dev/null "$j" || { echo "  -j$j FAILED"; return 1; }
            t1=$(date +%s%N)
            d=$(( (t1 - t0) / 1000 ))
            if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
        done
        if [ -z "$base" ]; then base=$best; fi
        # speedup to 2 decimals without floating point
        local sp=$(( base * 100 / best ))
        printf '  -j%-3s %7s us   %s.%02sx\n' "$j" "$best" "$(( sp / 100 ))" "$(printf '%02d' $(( sp % 100 )))"
    done
    rm -f /tmp/bp.out
}

tests/gen_big.sh 10000  > /tmp/bp_100k.v0
tests/gen_big.sh 100000 > /tmp/bp_1m.v0

run_size "100k lines" /tmp/bp_100k.v0
run_size "1M lines"   /tmp/bp_1m.v0
run_size "v1.v0 self-host" v1.v0

rm -f /tmp/bp_100k.v0 /tmp/bp_1m.v0
