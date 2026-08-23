#!/usr/bin/env bash
# check_saturation.sh -- symbol tables near their limits, across worker
# counts.
#
# This axis had no coverage at all, and it hid a hang that pinned every
# core indefinitely with no output and no diagnostic. Two defects
# compounded: the population ceiling was checked against the whole
# table's SYM_POP_MAX while a worker probes with a mask narrowed to a
# fraction of it, and the narrowing assumed each worker holds ~1/N of the
# symbols -- true for labels, false for equ constants, which are replayed
# into every worker in full. A worker's table filled, the probe loop
# found no empty slot, and walked the ring forever.
#
# -j8 survived because its mask is twice as wide, which is exactly why
# nothing noticed: testing one worker count is not testing this.
#
# Everything here runs under a timeout. A hang is a test failure, not a
# reason to go and find the process later.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0
T=${TIMEOUT:-25}

run() {  # run <name> <file> <jobs>
    if timeout "$T" $V "$2" "$D/out.$3" "$3" 2>"$D/e"; then return 0; fi
    rc=$?
    if [ $rc = 124 ]; then echo "FAIL $1 -j$3: TIMED OUT after ${T}s"; fail=1
    else echo "FAIL $1 -j$3: exit $rc: $(head -1 "$D/e")"; fail=1; fi
    return 1
}

# constant-heavy: the case that hung. Every constant lands in every
# worker's table regardless of worker count.
awk 'BEGIN {
  for (i = 0; i < 17000; i++) print "C" i " equ " i
  for (i = 0; i < 60000; i++) print "mov rax, rbx"
  print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
}' > "$D/consts.v0"

# label-heavy: stresses the same table from the other direction, where
# the 1/N assumption does hold.
awk 'BEGIN {
  for (i = 0; i < 120000; i++) { print "L" i ":"; print "mov rax, rbx" }
  print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
}' > "$D/labels.v0"

# both at once, which is what real source looks like.
awk 'BEGIN {
  for (i = 0; i < 10000; i++) print "K" i " equ " i
  for (i = 0; i < 80000; i++) { print "M" i ":"; print "mov rax, rbx" }
  print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
}' > "$D/both.v0"

for name in consts labels both; do
    src="$D/$name.v0"
    printf '%s: %s bytes\n' "$name" "$(wc -c < "$src")"
    run "$name" "$src" 1 || continue
    cp "$D/out.1" "$D/ser"
    for j in 2 4 8 16; do
        run "$name" "$src" "$j" || continue
        cmp -s "$D/ser" "$D/out.$j" \
            && echo "  ok   -j$j identical to serial" \
            || { echo "  FAIL -j$j differs from serial"; fail=1; }
    done
done

# CRLF: a Windows-authored source has to assemble. CR classified as
# nothing, so every line ended in "bad operand".
printf 'mov rax, 60\r\nmov rdi, 9\r\nsyscall\r\n' > "$D/crlf.v0"
if timeout "$T" $V "$D/crlf.v0" "$D/crlf" 2>"$D/e"; then
    "$D/crlf"; rc=$?
    [ "$rc" = 9 ] && echo "ok   CRLF source assembles and runs (exit 9)" \
        || { echo "FAIL CRLF: exit $rc, wanted 9"; fail=1; }
else
    echo "FAIL CRLF rejected: $(head -1 "$D/e")"; fail=1
fi

exit $fail
