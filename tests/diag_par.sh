#!/usr/bin/env bash
# diag_par.sh -- isolate which serial phase caps the speedup.
# Label-free input makes the merge trivial (nothing to install or
# resolve), so comparing it against label-heavy input separates
# "merge is the bottleneck" from "prescan/read is the bottleneck".
cd "$(dirname "$0")/.."
V=${1:-./v1}
REPS=${2:-5}

best_of() {
    local best="" t0 t1 d
    for _ in $(seq "$REPS"); do
        t0=$(date +%s%N); "$@" >/dev/null 2>&1; t1=$(date +%s%N)
        d=$(( (t1 - t0) / 1000 ))
        if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
    done
    echo "$best"
}

tests/gen_big.sh 100000 > /tmp/dg_lab.v0
awk '!/^skip/ && !/^jl /' /tmp/dg_lab.v0 > /tmp/dg_nolab.v0

for src in /tmp/dg_lab.v0 /tmp/dg_nolab.v0; do
    n=$(wc -l < "$src")
    l=$(grep -c '^skip' "$src")
    echo "=== $src  ($n lines, $l labels) ==="
    j1=$(best_of $V "$src" /dev/null 1)
    for j in 1 2 4 8 16; do
        t=$(best_of $V "$src" /dev/null "$j")
        sp=$(( j1 * 100 / t ))
        printf '  -j%-3s %7s us  %s.%02sx\n' "$j" "$t" "$(( sp / 100 ))" "$(printf '%02d' $(( sp % 100 )))"
    done
done
rm -f /tmp/dg_lab.v0 /tmp/dg_nolab.v0
