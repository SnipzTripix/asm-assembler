#!/usr/bin/env bash
# par_scaling.sh -- wall and CPU time per worker count, on an input large
# enough to take the parallel path.
cd "$(dirname "$0")/.."
V=${1:-./v1}
SRC=${2:-}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
if [ -z "$SRC" ]; then SRC="$D/big.v0"; tests/gen_big.sh 30000 > "$SRC"; fi
echo "input: $(wc -c < "$SRC") bytes"
for j in 1 2 4 8 16; do
    TIMEFORMAT='%R %U %S'
    t=$( { time $V "$SRC" /dev/null "$j" >/dev/null 2>&1; } 2>&1 )
    set -- $t
    printf '  -j%-3s wall %-8s user %-8s sys %-8s cpu/wall %s\n' \
        "$j" "$1" "$2" "$3" "$(awk -v u=$2 -v s=$3 -v r=$1 'BEGIN{if(r>0)printf "%.2f",(u+s)/r; else print "-"}')"
done
