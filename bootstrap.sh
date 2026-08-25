#!/usr/bin/env bash
# bootstrap.sh -- rebuild the assembler from source, trusting only nasm.
#
#   seed.asm --nasm--> seed
#   seed     --------> v1boot.v0 --> boot     (frozen bootstrap source)
#   boot     --------> v1.v0     --> stage1
#   stage1   --------> v1.v0     --> stage2
#   stage2   --------> v1.v0     --> stage3   (stage2 must equal stage3)
#
# The stage2 == stage3 equality is the real proof: stage2 was produced by a
# compiler that was itself produced from source, so if it reproduces itself
# byte for byte, the whole chain is reproducible from seed.asm alone. The
# committed ./v1 binary is then compared against it -- it is a convenience,
# not a dependency, and this is what proves it.
#
# Why there is a v1boot.v0. seed is deliberately crude and deliberately
# frozen: every line added to seed.asm enlarges the hand-verified trusted
# base. This script used to have seed assemble v1.v0 directly, which capped
# v1.v0 at whatever seed understands -- so the assembler could not use its
# own lea, test, neg, align, scaled-index or named-displacement forms on
# itself, and paid for it in both size and speed. v1boot.v0 is a frozen copy
# of v1.v0 from the day that changed. It stays inside seed's subset forever;
# v1.v0 is free.
#
# Nothing about the trust story changes. nasm and seed/seed.asm are still
# the only inputs anyone has to believe in. The chain is one link longer.
#
# Neither boot nor stage1 is expected to equal stage2. seed emits a
# redundant REX prefix on some forms and a different ELF header size, so
# `boot` differs from a self-hosted build while behaving identically, and
# stage1 differs from stage2 whenever v1.v0 has changed an encoding since
# the freeze. Only from stage2 onward is the output self-hosted and stable,
# which is why the fixed point is checked there.
set -u
cd "$(dirname "$0")"
fail=0

if ! command -v nasm >/dev/null 2>&1; then
    echo "bootstrap: nasm not found -- it is the one external tool this"
    echo "           chain requires (apt install nasm)." >&2
    exit 2
fi

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

echo "[1/6] nasm: seed.asm -> seed"
nasm -f bin seed/seed.asm -o "$D/seed" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/seed"

echo "[2/6] seed: v1boot.v0 -> boot"
if ! "$D/seed" < v1boot.v0 > "$D/boot" 2>"$D/err"; then
    cat "$D/err" >&2
    echo "bootstrap: seed could not assemble v1boot.v0. That file is frozen and" >&2
    echo "           must stay inside seed's subset -- if it was edited, revert it." >&2
    exit 1
fi
chmod +x "$D/boot"

echo "[3/6] boot: v1.v0 -> stage1"
"$D/boot" v1.v0 "$D/stage1" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/stage1"

echo "[4/6] stage1: v1.v0 -> stage2"
"$D/stage1" v1.v0 "$D/stage2" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/stage2"

echo "[5/6] stage2: v1.v0 -> stage3"
"$D/stage2" v1.v0 "$D/stage3" 2>"$D/err" || { cat "$D/err" >&2; exit 1; }
chmod +x "$D/stage3"

echo "[6/6] checks"
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
