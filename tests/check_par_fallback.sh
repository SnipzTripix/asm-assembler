#!/usr/bin/env bash
# check_par_fallback.sh -- a worker count must never turn a file that
# assembles into one that does not.
#
# Slot capacities are per CHUNK, so a label-dense file could exceed a
# worker's slot at -j2 (two big chunks) while succeeding at -j1 (no
# workers) and at -j4 (four small ones). It died, and the message advised
# retrying with FEWER jobs -- the direction that makes chunks bigger. The
# parent now discards the workers' output and assembles serially instead,
# so the only observable effect of a worker count is how long it takes.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

# 100k labels, comfortably past PAR_MIN_BYTES
awk 'BEGIN {
  for (i = 0; i < 100000; i++) { print "L" i ":"; print "mov rax, rbx" }
  print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
}' > "$D/many.v0"
echo "label-dense input: $(wc -c < "$D/many.v0") bytes, 100000 labels"

$V "$D/many.v0" "$D/ser" 1 2>"$D/e" || { echo "FAIL: serial: $(cat "$D/e")"; exit 1; }

for j in 2 3 4 8 16; do
    if ! $V "$D/many.v0" "$D/par" "$j" 2>"$D/e"; then
        echo "FAIL -j$j: $(cat "$D/e")"; fail=1; continue
    fi
    cmp -s "$D/ser" "$D/par" \
        && echo "ok   -j$j assembles, identical to serial" \
        || { echo "FAIL -j$j differs from serial"; fail=1; }
done

# The capacities were also raised, so the case above now fits and never
# reaches the fallback -- and with a 131072-label slot, a file big enough
# to overflow one chunk exceeds the serial symbol table first, as does
# any file dense enough to overflow the fixup slot. Emitted bytes are the
# one capacity a chunk can still exhaust while the serial path copes: a
# worker slot holds 6 MiB of text against the serial buffer's 64 MiB.
# 1.3M instructions at 10 bytes each is ~13 MiB of text, so each of two
# chunks needs ~6.5 MiB and cannot have it. This is the case that proves
# the fallback runs rather than merely existing.
awk 'BEGIN {
  for (i = 0; i < 1300000; i++) print "mov rax, 0x1122334455667788"
  print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
}' > "$D/huge.v0"
echo "over-capacity input: $(wc -c < "$D/huge.v0") bytes, ~13 MiB of text"

$V "$D/huge.v0" "$D/hser" 1 2>"$D/e" || { echo "FAIL: serial: $(cat "$D/e")"; exit 1; }
for j in 2 16; do
    if ! $V "$D/huge.v0" "$D/hpar" "$j" 2>"$D/e"; then
        echo "FAIL -j$j: $(cat "$D/e")"; fail=1; continue
    fi
    cmp -s "$D/hser" "$D/hpar" \
        && echo "ok   -j$j assembles, identical to serial" \
        || { echo "FAIL -j$j differs from serial"; fail=1; }
done

exit $fail
