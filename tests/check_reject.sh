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

echo "--- hex literals ---"
# 'Z'+1 was used where 'F'+1 belonged, so every letter A-Z took the
# uppercase-digit branch: G-Z became digit values 16..35 and `0xZZ`
# assembled silently as 595. Lowercase was never affected.
reject "uppercase G in hex"      'mov rax, 0xZZ\nret\n'
reject "uppercase G alone"       'mov rax, 0xG\nret\n'
reject "hex with no digits"      'mov rax, 0x\nret\n'
reject "hex no digits in db"     'db 0x\n'
value  "uppercase hex digits"  255 'mov rdi, 0xFF\nmov rax, 60\nsyscall\n'
value  "lowercase hex digits"  171 'mov rdi, 0xab\nmov rax, 60\nsyscall\n'
value  "mixed-case hex digits"  47 'mov rdi, 0x2F\nmov rax, 60\nsyscall\n'

echo "--- data directives must not truncate their operand ---"
reject "db over 8 bits"          'db 300\n'
reject "dw over 16 bits"         'dw 0x12345\n'
reject "dd over 32 bits"         'dd 0x1234567890\n'

echo "--- diagnostics must name the thing that is wrong ---"
# Each of these used to report something true but useless.
printf '%%macro foo 1\nret\n' > "$D/t.v0"
if $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
    echo "FAIL: %macro accepted"; fail=1
elif grep -q 'macro' "$D/e"; then
    echo "ok   unknown %% directive names itself -- $(cat "$D/e")"
else
    echo "FAIL: %macro reported as [$(cat "$D/e")]"; fail=1
fi
printf '%%include "no_such_file.inc"\nret\n' > "$D/t.v0"
if $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
    echo "FAIL: missing include accepted"; fail=1
elif grep -q 'no_such_file.inc' "$D/e"; then
    echo "ok   missing include names the file -- $(cat "$D/e")"
else
    echo "FAIL: missing include reported as [$(cat "$D/e")]"; fail=1
fi

echo "--- assembling a file over itself must not destroy it ---"
# This exited 0 and produced a working binary, having overwritten the
# source with it. Both spellings of the same file have to be caught, so
# the check compares device and inode rather than the path strings.
printf 'mov rax, 60\nmov rdi, 0\nsyscall\n' > "$D/self.v0"
before=$(wc -c < "$D/self.v0")
if (cd "$D" && "$OLDPWD/$V" self.v0 self.v0 2>/dev/null); then
    echo "FAIL: assembled over its own input"; fail=1
else
    [ "$(wc -c < "$D/self.v0")" = "$before" ] \
        && echo "ok   refused, source intact ($before bytes)" \
        || { echo "FAIL: source was modified anyway"; fail=1; }
fi
if (cd "$D" && "$OLDPWD/$V" ./self.v0 self.v0 2>/dev/null); then
    echo "FAIL: ./x and x not recognised as the same file"; fail=1
else
    echo "ok   ./x and x recognised as the same file"
fi

echo "--- still accepted: these are valid and must keep working ---"
value  "comment after statement" 7 'mov rdi, 7   ; trailing comment\nmov rax, 60\nsyscall\n'
value  "tabs and spaces"         9 '\tmov  rdi,\t9\n\tmov rax, 60\n\tsyscall\n'
value  "label then statement"   11 'start: mov rdi, 11\nmov rax, 60\nsyscall\n'
value  "max shift count"         0 'mov rax, 1\nshl rax, 63\nmov rdi, 0\nmov rax, 60\nsyscall\n'
value  "negative equ"            5 'M equ -1\nmov rdi, 4\nsub rdi, M\nmov rax, 60\nsyscall\n'
value  "db accepts both signs"   0 'mov rdi, 0\nmov rax, 60\nsyscall\ndb -1\ndb 0xFF\n'

exit $fail
