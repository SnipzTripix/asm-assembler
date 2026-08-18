#!/usr/bin/env bash
# check_review.sh -- regressions for the defects found in code review.
# Each of these produced a silently broken binary or a wrong diagnostic.
cd "$(dirname "$0")/.."
V=${1:-./v1}
fail=0
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

chk() { # chk <name> <want-exit> <src>
    $V "$3" "$D/o" 2>"$D/e" || { echo "FAIL $1: $(cat "$D/e")"; fail=1; return; }
    "$D/o"; local got=$?
    [ "$got" = "$2" ] && echo "ok   $1" \
        || { echo "FAIL $1: exit $got, wanted $2"; fail=1; }
}

# .bss present with no .data: the segment used to be omitted entirely
chk ".bss with no .data" 42 tests/regress_review.v0
# .data must be writable, not R-only
chk "writable .data"      5 tests/regress_writable.v0

# label sharing a line with its statement must not drop the statement
printf '.text\nstart: mov rdi, 33\nmov rax, 60\nsyscall\n' > "$D/lbl.v0"
chk "label: stmt on one line" 33 "$D/lbl.v0"

# an executable stack is a defect, not a default
$V tests/regress_review.v0 "$D/o" && readelf -l "$D/o" 2>/dev/null | grep -q GNU_STACK \
    && echo "ok   PT_GNU_STACK emitted" || { echo "FAIL no PT_GNU_STACK"; fail=1; }

# output buffer overrun must be caught, not silently corrupt neighbours
printf '.bss\nb: resb 2147483647\n' > "$D/big.v0"
$V "$D/big.v0" "$D/o" 2>"$D/e"
[ $? -ne 0 ] && echo "ok   oversized resb rejected: $(cat "$D/e")" \
             || { echo "FAIL oversized resb accepted"; fail=1; }

# a failed assembly must not leave an executable behind
rm -f "$D/leftover"
printf 'bogusmnemonic\n' > "$D/bad.v0"
$V "$D/bad.v0" "$D/leftover" 2>/dev/null
[ ! -e "$D/leftover" ] && echo "ok   no output file left after failure" \
                       || { echo "FAIL 0-byte executable left behind"; fail=1; }

# unterminated string gets its own message
printf 'db "abc\n' > "$D/unt.v0"
$V "$D/unt.v0" "$D/o" 2>"$D/e"
grep -q "unterminated" "$D/e" && echo "ok   unterminated string diagnosed" \
                              || { echo "FAIL: $(cat "$D/e")"; fail=1; }

# include errors must not print a garbage column
printf '%%include "%s/self.v0"\n' "$D" > "$D/self.v0"
$V "$D/self.v0" "$D/o" 2>"$D/e"
grep -q "col" "$D/e" && { echo "FAIL bogus column: $(cat "$D/e")"; fail=1; } \
                     || echo "ok   include error has no bogus position"

# line numbers must agree between serial and parallel
{ echo ".text"; i=0; while [ $i -lt 40000 ]; do echo "mov rax, rbx"; i=$((i+1)); done
  echo "add rax, 0x123456789"; } > "$D/ln.v0"
s=$($V "$D/ln.v0" "$D/o" 1 2>&1 | head -1)
p=$($V "$D/ln.v0" "$D/o" 4 2>&1 | head -1)
[ "$s" = "$p" ] && echo "ok   line numbers agree serial vs -j4" \
                || { echo "FAIL line numbers differ:"; echo "  $s"; echo "  $p"; fail=1; }

exit $fail
