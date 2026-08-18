#!/usr/bin/env bash
# check_reject.sh -- what the assembler must REFUSE.
#
# The existing suite verifies that correct input produces correct bytes:
# the fixed point and the cross-product difftest cover the encoder
# thoroughly. Nothing covered the parser's willingness to ACCEPT garbage,
# which is why a batch of silent-wrong-output bugs sat undetected -- each
# one produced a plausible binary rather than an error. Every case here
# assembled "successfully" and emitted wrong code at some point.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

# reject <name> <source>  -- must exit nonzero with a diagnostic
reject() {
    printf '%b' "$2" > "$D/t.v0"
    if $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
        echo "FAIL $1: accepted (should be rejected)"
        fail=1
    elif [ ! -s "$D/e" ]; then
        echo "FAIL $1: rejected but printed no diagnostic"
        fail=1
    else
        echo "ok   $1 -- $(head -1 "$D/e")"
    fi
}

# value <name> <wanted-exit> <source>  -- must assemble AND behave
value() {
    printf '%b' "$3" > "$D/t.v0"
    if ! $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
        echo "FAIL $1: rejected: $(head -1 "$D/e")"; fail=1; return
    fi
    "$D/t.bin"; local got=$?
    [ "$got" = "$2" ] && echo "ok   $1 (exit $got)" \
        || { echo "FAIL $1: exit $got, wanted $2"; fail=1; }
}

echo "--- trailing garbage after a complete statement ---"
reject "two operands, no comma"  'mov rax, rbx rcx\n'
reject "trailing token"          'mov rax, rbx zzz\n'
reject "trailing comma"          'mov rax, 1,\n'
reject "extra operand"           'add rax, rbx, rcx\n'
reject "garbage after ret"       'ret ret\n'
reject "garbage after syscall"   'syscall 5\n'

echo "--- expressions are not supported, so they must not be misread ---"
reject "addition in immediate"   'mov rdi, 4+2\n'
reject "subtraction in operand"  'mov rdi, 8-1\n'

echo "--- db list forms: silently emitted only the first element ---"
reject "db numeric list"         'db 1, 2, 3\n'
reject "db string then bytes"    'db "hi", 10, 0\n'

echo "--- equ must resolve or fail, never yield zero ---"
value  "equ alias resolves"   4 'A equ 4\nB equ A\nmov rdi, B\nmov rax, 60\nsyscall\n'
reject "equ to unknown name"     'B equ ZZZ\nmov rdi, B\nmov rax, 60\nsyscall\n'

echo "--- ranges ---"
reject "shift count over 255"    'shl rax, 300\n'
reject "shift count over 63"     'shl rax, 100\n'
reject "immediate over 64 bits"  'mov rax, 99999999999999999999999\n'
reject "displacement over 32 bits" 'mov rax, [rbx+99999999999]\n'

echo "--- data directives must not truncate their operand ---"
reject "db over 8 bits"          'db 300\n'
reject "dw over 16 bits"         'dw 0x12345\n'
reject "dd over 32 bits"         'dd 0x1234567890\n'

echo "--- still accepted: these are valid and must keep working ---"
value  "comment after statement" 7 'mov rdi, 7   ; trailing comment\nmov rax, 60\nsyscall\n'
value  "tabs and spaces"         9 '\tmov  rdi,\t9\n\tmov rax, 60\n\tsyscall\n'
value  "label then statement"   11 'start: mov rdi, 11\nmov rax, 60\nsyscall\n'
value  "max shift count"         0 'mov rax, 1\nshl rax, 63\nmov rdi, 0\nmov rax, 60\nsyscall\n'
value  "negative equ"            5 'M equ -1\nmov rdi, 4\nsub rdi, M\nmov rax, 60\nsyscall\n'
value  "db accepts both signs"   0 'mov rdi, 0\nmov rax, 60\nsyscall\ndb -1\ndb 0xFF\n'

exit $fail
