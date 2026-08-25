#!/usr/bin/env bash
# check_self_par.sh -- assemble the real source through the parallel path.
#
# v1.v0 is a few KB under PAR_MIN_BYTES, so every self-assembly in this
# suite -- the fixed point, the bootstrap, determinism.sh -- takes the
# serial fallback at every worker count. The most-run input in the project
# has never touched the parallel path, and on the day the source crosses
# 256 KB it will start to, silently and without any test changing.
#
# Comments emit nothing, so padding the source with them must produce a
# byte-identical binary. That is the whole test: pad past the threshold,
# assemble at every worker count, and require all of it to equal the
# ordinary serial build of the unpadded source.
#
# This is also cheap insurance against the reverse: if PAR_MIN_BYTES is
# ever lowered, or the source shrinks back under, the padding is computed
# from the threshold rather than fixed, so the test keeps testing.
set -u
cd "$(dirname "$0")/.."
V=${1:-./v1}
SRC=${2:-v1.v0}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

MIN=$(grep -m1 '^PAR_MIN_BYTES' v1.v0 | awk '{print $3}')
[ -n "$MIN" ] || { echo "FAIL: could not read PAR_MIN_BYTES from v1.v0"; exit 1; }

# An `align` anywhere in the source forces the whole file onto the serial
# path -- a worker cannot know its chunk's final base, so it reports the
# directive and the parent throws every slot away. That is correct, and it
# would also make everything below vacuous: -j1 through -j16 would agree
# because they all ran serially. Measured on this source padded past the
# threshold, -j16 with an align costs 7.3 ms against 5.7 ms serial, having
# forked sixteen workers to discard their output.
#
# So: if v1.v0 ever starts using align, this test has to be rewritten, not
# quietly kept.
if grep -qE '^align ' "$SRC"; then
    echo "FAIL: $SRC uses `align`, which forces the serial fallback -- every"
    echo "     comparison below would pass without exercising the parallel"
    echo "     path at all. Decide deliberately: drop the align, or replace"
    echo "     this test with one that means something."
    exit 1
fi

sz=$(wc -c < "$SRC")
need=$(( MIN - sz + 4096 ))
[ "$need" -lt 0 ] && need=0

# The reference: the source exactly as committed, assembled serially.
$V "$SRC" "$D/ref" 1 2>"$D/e" || { echo "FAIL: serial build of $SRC: $(head -1 "$D/e")"; exit 1; }

cp "$SRC" "$D/pad.v0"
awk -v n="$need" 'BEGIN { lines = int(n / 40) + 2
    for (i = 0; i < lines; i++)
        print "; padding, so this file clears PAR_MIN_BYTES and the real" }' >> "$D/pad.v0"
psz=$(wc -c < "$D/pad.v0")
if [ "$psz" -lt "$MIN" ]; then
    echo "FAIL: padded source is ${psz}B, still under PAR_MIN_BYTES ($MIN)"
    exit 1
fi

# Padding with comments must not change a byte of output.
$V "$D/pad.v0" "$D/pad1" 1 2>"$D/e" || { echo "FAIL: serial build of padded source: $(head -1 "$D/e")"; exit 1; }
if ! cmp -s "$D/ref" "$D/pad1"; then
    echo "FAIL: comment padding changed the serial output -- the rest of this"
    echo "     test would be comparing against the wrong thing"
    fail=1
fi

bad=""
for j in 2 3 5 8 16; do
    if ! $V "$D/pad.v0" "$D/pad$j" "$j" 2>"$D/e"; then
        bad="$bad -j$j($(head -1 "$D/e"))"; continue
    fi
    cmp -s "$D/ref" "$D/pad$j" || bad="$bad -j$j(differs)"
done
if [ -n "$bad" ]; then
    echo "FAIL: the assembler's own source assembles differently in parallel:$bad"
    fail=1
else
    echo "ok   $SRC (${sz}B) padded to ${psz}B: identical at -j1..16"
fi

# And the padded build has to be a working assembler, not merely identical
# bytes -- a comparison against a broken reference would still pass.
chmod +x "$D/pad16"
if "$D/pad16" "$SRC" "$D/gen2" 2>"$D/e"; then
    cmp -s "$D/ref" "$D/gen2" \
        && echo "ok   the parallel-built assembler reproduces the source binary" \
        || { echo "FAIL: parallel-built assembler produced a different binary"; fail=1; }
else
    echo "FAIL: parallel-built assembler cannot assemble: $(head -1 "$D/e")"; fail=1
fi

[ $fail -eq 0 ] && echo "SELF PAR OK"
exit $fail
