#!/usr/bin/env bash
# bench_io.sh -- split v1's fixed cost into "work" vs "output file I/O",
# by sending the output to a real file vs /dev/null vs a closed pipe.
cd "$(dirname "$0")/.."
V=${1:-./v1}
REPS=${2:-20}
printf 'ret\n' > /tmp/io.v0

timeit() {  # timeit <description> <command...>
    local label="$1"; shift
    local best="" t0 t1 d
    for _ in $(seq "$REPS"); do
        t0=$(date +%s%N); "$@" >/dev/null 2>&1; t1=$(date +%s%N)
        d=$(( (t1 - t0) / 1000 ))
        if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
    done
    printf '%-34s %6s us\n' "$label" "$best"
}

timeit "v1 -> real file (argv)"     $V /tmp/io.v0 /tmp/io.out
timeit "v1 -> /dev/null (argv)"     $V /tmp/io.v0 /dev/null
echo
echo "output size for a 1-line program: $(wc -c < /tmp/io.out) bytes"
echo "  (of which actual code+headers:  $(( 176 + 1 )) bytes)"
rm -f /tmp/io.v0 /tmp/io.out
