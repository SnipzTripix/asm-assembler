#!/usr/bin/env bash
# par_equiv.sh -- the correctness oracle for parallel assembly: for every
# input, at every worker count, the output must be byte-identical to what
# the serial path produces. Parallelism may make it faster, never
# different.
#
# CRITICAL: the inputs must exceed PAR_MIN_BYTES, or v1 silently runs the
# serial path and this whole file passes while testing nothing. That is
# exactly what happened -- every committed test input was under the
# threshold, so a layout collision that broke every parallel run went
# unnoticed. The threshold is read from the source here rather than
# hardcoded, so raising it cannot quietly disarm these tests again.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

MIN=$(grep -oE '^PAR_MIN_BYTES   equ [0-9]+' v1.v0 | grep -oE '[0-9]+$')
[ -n "$MIN" ] || { echo "par_equiv: could not read PAR_MIN_BYTES"; exit 1; }

# Build an input comfortably past the threshold, with labels and
# cross-chunk references so the merge is genuinely exercised.
big="$D/big.v0"
tests/gen_big.sh 30000 > "$big"
sz=$(wc -c < "$big")
if [ "$sz" -le "$MIN" ]; then
    echo "par_equiv: generated input ($sz B) does not exceed PAR_MIN_BYTES ($MIN B)"
    exit 1
fi
echo "input $sz bytes, threshold $MIN -- parallel path will be taken"

# --- forking really happens: with N workers busy, CPU time must exceed
# wall time. A serial fallback cannot do that. ---
# Output goes to /dev/null so the measurement is of assembly, not of the
# filesystem. At -j8 this machine sees cpu/wall around 3; anything above
# 1.5 is impossible without several cores actually running at once, and
# is what a silent serial fallback could never produce.
TIMEFORMAT='%R %U %S'
$V "$big" /dev/null 8 >/dev/null 2>&1     # warm the page cache first: on a
$V "$big" /dev/null 8 >/dev/null 2>&1     # cold run first-touch faults
                                          # serialise the workers and the
                                          # ratio says nothing
best=0; real=0; user=0; sys=0
for _ in 1 2 3; do
    t=$( { time $V "$big" /dev/null 8 >/dev/null 2>&1; } 2>&1 )
    set -- $t
    r=$(awk -v u="$2" -v s="$3" -v w="$1" 'BEGIN{if(w>0)printf "%.3f",(u+s)/w; else print 0}')
    if awk -v a="$r" -v b="$best" 'BEGIN{exit !(a>b)}'; then
        best=$r; real=$1; user=$2; sys=$3
    fi
done
if awk -v u="$user" -v s="$sys" -v r="$real" 'BEGIN{exit !(r>0 && (u+s) > r*1.5)}'; then
    echo "ok   forked: $(awk -v u=$user -v s=$sys -v r=$real 'BEGIN{printf "%.2f", (u+s)/r}')x cpu/wall at -j8"
else
    echo "FAIL no evidence of parallelism: user=$user sys=$sys real=$real"
    fail=1
fi

for src in "$big" tests/hello.v0 tests/edge.v0 tests/sections.v0 v1.v0; do
    name=$(basename "$src")
    $V "$src" "$D/ser" 1 2>"$D/ser.err" || {
        echo "FAIL $name: serial assembly failed: $(cat "$D/ser.err")"; fail=1; continue; }
    for j in 2 3 4 8 16; do
        $V "$src" "$D/par" "$j" 2>"$D/par.err" || {
            echo "FAIL $name -j$j: $(cat "$D/par.err")"; fail=1; continue; }
        if cmp -s "$D/ser" "$D/par"; then
            echo "ok   $name -j$j"
        else
            echo "FAIL $name -j$j DIFFERS from serial"
            cmp "$D/ser" "$D/par" | head -2
            fail=1
        fi
    done
done

[ $fail -eq 0 ] && echo "PAR EQUIV OK" || echo "PAR EQUIV FAILURES"
exit $fail
