#!/usr/bin/env bash
# check_align.sh -- `align N` puts the next byte on an N-byte boundary.
#
# This exists because of a measurement rather than a feature request:
# ~300 bytes of unrelated .text moved self-assembly by 26%, and a 7-byte
# shift held the difference. Until a hot loop can be pinned to a
# boundary, every change under about 30% on this codebase measures
# placement rather than itself. So the assertions here are about the
# addresses that come out, not about the bytes going in.
set -u
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

run() { # run <name> <wanted-exit> <source>
    printf '%b' "$3" > "$D/t.v0"
    if ! $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
        echo "FAIL $1: rejected: $(head -1 "$D/e")"; fail=1; return
    fi
    chmod +x "$D/t.bin"; "$D/t.bin" >/dev/null 2>&1; local got=$?
    [ "$got" = "$2" ] && echo "ok   $1" \
        || { echo "FAIL $1: exit $got, wanted $2 (a nonzero low bit means"
             echo "     the label was not on its boundary)"; fail=1; }
}
bad() { # bad <name> <source>
    printf '%b' "$2" > "$D/t.v0"
    if $V "$D/t.v0" "$D/t.bin" 2>"$D/e"; then
        echo "FAIL $1: accepted"; fail=1
    else
        echo "ok   $1 -- $(head -1 "$D/e")"
    fi
}

# Each case exits with the misalignment it measured, so 0 is the pass.
# LOAD_BASE and both non-.text section starts are page-aligned, so the
# low bits of a label's runtime address are the low bits of its offset.
echo "--- .text ---"
run ".text aligned to 32" 0 \
'mov rax, one\nand rax, 31\nmov rdi, rax\nmov rax, 60\nsyscall\ndb 1\ndb 2\ndb 3\nalign 32\none:\ndb 0\n'
run ".text aligned to 16, twice over" 0 \
'mov rax, one\nand rax, 15\nmov rcx, two\nand rcx, 15\nadd rax, rcx\nmov rdi, rax\nmov rax, 60\nsyscall\ndb 1\nalign 16\none:\ndb 1\ndb 2\nalign 16\ntwo:\ndb 0\n'
run "align on an already-aligned cursor is a no-op" 0 \
'mov rax, one\nmov rcx, two\nsub rax, rcx\nmov rdi, rax\nmov rax, 60\nsyscall\nalign 8\ntwo:\nalign 8\none:\ndb 0\n'
run "align 1 pads nothing" 0 \
'mov rax, one\nmov rcx, two\nsub rax, rcx\nmov rdi, rax\nmov rax, 60\nsyscall\ntwo:\nalign 1\none:\ndb 0\n'

echo "--- .data and .bss ---"
run ".data aligned to 16" 0 \
'mov rax, dv\nand rax, 15\nmov rdi, rax\nmov rax, 60\nsyscall\n.data\ndb 1\nalign 16\ndv: dq 7\n'
run ".bss aligned to 32" 0 \
'mov rax, b2\nand rax, 31\nmov rdi, rax\nmov rax, 60\nsyscall\n.bss\nb1: resb 1\nalign 32\nb2: resb 8\n'
run ".bss padding is a reservation, not an emission" 7 \
'mov rax, b2\nmov rcx, 7\nmov [rax+0], rcx\nmov rdi, [rax+0]\nmov rax, 60\nsyscall\n.bss\nb1: resb 3\nalign 32\nb2: resb 8\n'

echo "--- .text padding is nop, not zero ---"
# 00 00 is `add [rax], al`, which faults; 0x90 is a legal instruction, so
# falling into the padding has to be survivable.
printf '%b' 'jmp past\ndb 1\nalign 16\npast:\nmov rdi, 5\nmov rax, 60\nsyscall\n' > "$D/t.v0"
$V "$D/t.v0" "$D/t.bin" 2>"$D/e"
if od -An -tx1 -j 288 -N 64 "$D/t.bin" | tr -s ' ' '\n' | grep -qx 90; then
    echo "ok   padding byte is 0x90"
else
    echo "FAIL padding byte is not 0x90:"; od -An -tx1 -j 288 -N 32 "$D/t.bin"
    fail=1
fi

echo "--- rejected ---"
bad "align 0"          'align 0\nmov rax, 60\nsyscall\n'
bad "align 3"          'align 3\nmov rax, 60\nsyscall\n'
bad "align 64"         'align 64\nmov rax, 60\nsyscall\n'
bad "align -1"         'align -1\nmov rax, 60\nsyscall\n'
bad "align, no operand" 'align\nmov rax, 60\nsyscall\n'
bad "align 16 junk"    'align 16 junk\nmov rax, 60\nsyscall\n'

echo "--- parallel: align forces the serial fallback, output unchanged ---"
# No worker can honour an align: the padding a chunk needs depends on
# where the merge places it. The worker reports it like a chunk that
# outgrew its slot, and the parent reassembles serially -- so the output
# must still be byte-identical at every worker count, and still aligned.
MIN=$(grep -m1 '^PAR_MIN_BYTES' v1.v0 | awk '{print $3}')
awk -v minb="$MIN" 'BEGIN {
    print "mov rax, tgt"; print "and rax, 31"; print "mov rdi, rax"
    for (i = 0; i < int(minb / 11) + 8000; i++) print "mov rbx, " (i % 97)
    print "mov rax, 60"; print "syscall"
    print "db 1"; print "align 32"; print "tgt:"; print "db 0"
}' > "$D/big.v0"
sz=$(wc -c < "$D/big.v0")
[ "$sz" -ge "$MIN" ] || { echo "FAIL: ${sz}B under PAR_MIN_BYTES"; fail=1; }
if $V "$D/big.v0" "$D/b1" 1 2>"$D/e"; then
    bad=""
    for j in 2 3 8 16; do
        $V "$D/big.v0" "$D/b$j" "$j" 2>"$D/e" || { bad="$bad -j$j(error)"; continue; }
        cmp -s "$D/b1" "$D/b$j" || bad="$bad -j$j(differs)"
    done
    chmod +x "$D/b1" "$D/b16"
    "$D/b1" >/dev/null 2>&1;  s=$?
    "$D/b16" >/dev/null 2>&1; p=$?
    [ "$s" = 0 ] && [ "$p" = 0 ] || bad="$bad (misaligned: serial=$s par=$p)"
    if [ -n "$bad" ]; then echo "FAIL parallel align:$bad"; fail=1
    else echo "ok   parallel align (${sz}B, identical at -j1..16, still aligned)"; fi
else
    echo "FAIL parallel align: serial assembly failed: $(head -1 "$D/e")"; fail=1
fi

[ $fail -eq 0 ] && echo "ALIGN OK"
exit $fail
