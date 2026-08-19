#!/usr/bin/env bash
# regress_range.sh -- the silent-wrong-encoding bugs found by probing.
# Each must now either produce the CORRECT bytes or a clear error, never a
# quietly truncated or biased encoding.
#
# This used to print its results for a human to read, and nothing checked
# them. That is how it came to sit in the suite for weeks reporting
#   --- equ forward reference: expect imm 05 00 ... ---
#   0000000 00 00 00 00 00 00 00 00 ...
# under a green "ALL PASS": the dump offset was hardcoded to 177, the ELF
# header grew when PT_GNU_STACK was added, and the script was reading the
# program header table instead of the code. The encoding was right the
# whole time -- but a test that cannot fail could not have told anyone
# either way. It asserts now, and it finds the code from the end of the
# file rather than from a magic offset.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

# emits <name> <expected-hex-tail> <source>
emits() {
    printf '%b' "$3" > "$D/t.v0"
    if ! $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
        echo "FAIL $1: rejected: $(cat "$D/e")"; fail=1; return
    fi
    local n=$(( $(printf '%s' "$2" | wc -w) ))
    local got=$(tail -c "$n" "$D/t.bin" | od -An -t x1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')
    [ "$got" = "$2" ] && echo "ok   $1 -- $got" \
        || { echo "FAIL $1: got [$got] wanted [$2]"; fail=1; }
}

# errors <name> <source>
errors() {
    printf '%b' "$2" > "$D/t.v0"
    if $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
        echo "FAIL $1: accepted, should be an error"; fail=1
    else
        echo "ok   $1 -- $(cat "$D/e")"
    fi
}

# A forward-referenced equ used to resolve as if it were a label address,
# producing 0x400005 instead of 5.
emits  "equ forward reference" \
       "48 b8 05 00 00 00 00 00 00 00 c3" \
       'mov rax, LATER\nLATER equ 5\nret\n'

errors "disp32 overflow"      'mov rax, [rbx+99999999999]\nret\n'
errors "imm32 overflow"       'add rax, 0x123456789\nret\n'
errors "imm64 overflow"       'mov rax, 99999999999999999999999\nret\n'

# The boundaries themselves must still assemble -- an over-eager range
# check is the same bug wearing the opposite sign. (add/sub go through
# the general 81 /digit form -- this dialect has no accumulator-specific
# short opcode, which is a size choice, not a correctness one.)
# 0xFFFFFFFFFFFFFFFF is -1, so the sign-extended imm32 form sets exactly
# the same bits in three fewer bytes. The value still has to survive
# parsing at full width, which is what this is really testing.
emits  "unsigned imm64 max" \
       "48 c7 c0 ff ff ff ff c3" \
       'mov rax, 18446744073709551615\nret\n'
emits  "imm64 that needs all 64 bits" \
       "48 b8 f0 de bc 9a 78 56 34 12 c3" \
       'mov rax, 0x123456789ABCDEF0\nret\n'
emits  "imm32 boundaries" \
       "48 81 c0 ff ff ff 7f 48 81 e8 00 00 00 80 c3" \
       'add rax, 2147483647\nsub rax, -2147483648\nret\n'
emits  "disp32 boundaries" \
       "48 8b 8b ff ff ff 7f 48 8b 93 00 00 00 80 c3" \
       'mov rcx, [rbx+2147483647]\nmov rdx, [rbx-2147483648]\nret\n'

[ $fail -eq 0 ] && echo "RANGE REGRESSIONS OK" || echo "RANGE REGRESSION FAILURES"
exit $fail
