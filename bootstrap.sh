#!/usr/bin/env bash
# bootstrap.sh -- rebuild the assembler from source, trusting only nasm.
#
#   seed.asm --nasm--> seed --> v1.v0 --> stage1
#   stage1   --------> v1.v0 --> stage2
#   stage2   --------> v1.v0 --> stage3      (stage2 must equal stage3)
#
# The stage2 == stage3 equality is the real proof: stage2 was produced by a
# compiler that was itself produced from source, so if it reproduces itself
# byte for byte, the whole chain is reproducible from seed.asm alone. The
# committed ./v1 binary is then compared against it -- it is a convenience,
# not a dependency, and this is what proves it.
#
# stage1 is NOT expected to equal stage2. seed is a cruder assembler: it
# emits a redundant REX prefix on some forms and a different ELF header
# size, so the binary it produces differs from a self-hosted one while
# behaving identically. Only from stage2 onward is the output self-hosted
# and stable, which is why the fixed point is checked there.
set -u
cd "$(dirname "$0")"
fail=0

if ! command -v nasm >/dev/null 2>&1; then
    echo "bootstrap: nasm not found -- it is the one external tool this"
    echo "           chain requires (apt install nasm)." >&2
    exit 2
fi

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

echo "[1/5] nasm: seed.asm -> seed"
nasm -f bin seed/seed.asm -o "$D/seed" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/seed"

echo "[2/5] seed: v1.v0 -> stage1"
"$D/seed" < v1.v0 > "$D/stage1" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/stage1"

echo "[3/5] stage1: v1.v0 -> stage2"
"$D/stage1" v1.v0 "$D/stage2" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/stage2"

echo "[4/5] stage2: v1.v0 -> stage3"
"$D/stage2" v1.v0 "$D/stage3" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/stage3"

echo "[5/5] checks"
if cmp -s "$D/stage2" "$D/stage3"; then
    echo "  ok   stage2 == stage3 ($(wc -c < "$D/stage2") bytes) -- reproducible from seed.asm"
else
    echo "  FAIL stage2 != stage3: the chain does not converge" >&2
    fail=1
fi

if cmp -s "$D/stage2" v1; then
    echo "  ok   committed ./v1 matches the rebuilt compiler exactly"
else
    echo "  WARN committed ./v1 differs from the freshly bootstrapped stage2."
    echo "       Rebuild it with:  cp $D/stage2 v1   (then rerun tests)"
    fail=1
fi

exit $fail
