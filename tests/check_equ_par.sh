#!/usr/bin/env bash
# check_equ_par.sh -- `NAME equ OTHER_NAME` resolves the same serially and
# in parallel.
#
# The two paths resolve constants with different code. Serially, parse_stmt
# looks the name up in the symbol table. In parallel, the prescan harvests
# every equ into a flat array *instead of* the table (workers would
# otherwise inherit those pages and the parent's full-size hash mask), so
# it cannot use the table lookup and has its own resolver. Two resolvers
# for one language rule is exactly the shape of a bug that only appears
# above PAR_MIN_BYTES, which is why this input is padded past it.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

MIN=$(grep -oE '^PAR_MIN_BYTES   equ [0-9]+' v1.v0 | grep -oE '[0-9]+$')

{
    echo "A equ 41"
    echo "B equ A"                     # alias of a constant
    echo "C equ B"                     # alias of an alias
    echo "NEG equ -3"                  # negative: parse_imm alone read 0
    awk 'BEGIN { for (i = 0; i < 40000; i++) print "mov rax, rbx" }'
    echo "mov rdi, C"
    echo "add rdi, 1"
    echo "add rdi, NEG"                # 41 + 1 - 3 = 39
    echo "mov rax, 60"
    echo "syscall"
} > "$D/alias.v0"

sz=$(wc -c < "$D/alias.v0")
[ "$sz" -gt "$MIN" ] || { echo "FAIL: input $sz B is under PAR_MIN_BYTES $MIN B"; exit 1; }

$V "$D/alias.v0" "$D/ser" 1 || { echo "FAIL: serial assembly"; exit 1; }
"$D/ser"; got=$?
[ "$got" = 39 ] && echo "ok   serial equ alias (exit $got)" \
    || { echo "FAIL serial: exit $got, wanted 39"; fail=1; }

for j in 2 4 8; do
    $V "$D/alias.v0" "$D/par" "$j" 2>"$D/e" || {
        echo "FAIL -j$j: $(cat "$D/e")"; fail=1; continue; }
    cmp -s "$D/ser" "$D/par" \
        && echo "ok   -j$j identical to serial" \
        || { echo "FAIL -j$j differs from serial"; fail=1; }
done

exit $fail
