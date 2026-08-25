#!/usr/bin/env bash
# check_par_diag.sh -- a failing build says the same thing at every worker
# count.
#
# Workers used to write their diagnostics straight to the shared fd 2, on
# the reasoning that sharing the descriptor meant no marshalling was
# needed. Marshalling was exactly what was needed. Each diagnostic is six
# write(2) calls, so messages from different workers interleaved mid-word,
# and a file with an error in every chunk printed one line per chunk
# instead of one per file:
#
#   v1: unknown mnemonicv1: unknown mnemonic at line  at line 2504 col 32542
#
# Note the column in that line: two workers' digits ran together into a
# number that still looks perfectly valid. A format check would pass it.
# So this test compares against the serial output byte for byte rather
# than checking the shape, and repeats, because the failure is a race --
# 39 runs in 60, not 60 in 60.
#
# Exit status was always right and no bad binary was ever produced, so
# this is diagnostic quality rather than wrong output. It still lands on
# the headline property: -j must not change what the user is told.
set -u
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0
REPEAT=${PAR_DIAG_REPEAT:-40}

MIN=$(grep -m1 '^PAR_MIN_BYTES' v1.v0 | awk '{print $3}')
[ -n "$MIN" ] || { echo "FAIL: could not read PAR_MIN_BYTES from v1.v0"; exit 1; }

# An error in every chunk is the whole point: one error only ever produced
# one message, which is why this went unnoticed.
gen() { # gen <every-n-statements> <out>
    awk -v every="$1" -v minb="$MIN" 'BEGIN {
        n = int(minb / 13) + 20000
        for (i = 0; i < n; i++) {
            print "mov rax, rbx"
            if (i % every == 500) print "zzbad" i
        }
        print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
    }' > "$2"
}

check() { # check <name> <input>
    local name="$1" in="$2"
    local sz; sz=$(wc -c < "$in")
    if [ "$sz" -lt "$MIN" ]; then
        echo "FAIL $name: ${sz}B is under PAR_MIN_BYTES ($MIN) -- this would"
        echo "     run serially and assert nothing"; fail=1; return
    fi
    $V "$in" "$D/out" 1 2>"$D/serial" >/dev/null
    local src=$?
    if [ "$src" = 0 ]; then
        echo "FAIL $name: serial build unexpectedly succeeded"; fail=1; return
    fi
    if [ "$(wc -l < "$D/serial")" != 1 ]; then
        echo "FAIL $name: serial printed $(wc -l < "$D/serial") lines, wanted 1"
        fail=1; return
    fi
    local bad=""
    for j in 2 3 5 8 16; do
        local k=0
        while [ "$k" -lt "$REPEAT" ]; do
            $V "$in" "$D/out" "$j" 2>"$D/par" >/dev/null
            local prc=$?
            if ! cmp -s "$D/serial" "$D/par"; then
                bad="$bad -j$j(differs)"
                echo "     serial: $(cat "$D/serial")"
                echo "     -j$j:   $(cat "$D/par")"
                break
            fi
            [ "$prc" = "$src" ] || { bad="$bad -j$j(exit $prc vs $src)"; break; }
            k=$((k + 1))
        done
    done
    if [ -n "$bad" ]; then echo "FAIL $name:$bad"; fail=1; return; fi
    echo "ok   $name (${sz}B, $REPEAT runs x 5 worker counts, all identical to serial)"
}

gen 1000 "$D/every.v0";  check "an error in every chunk"      "$D/every.v0"
gen 9000 "$D/sparse.v0"; check "errors in a few chunks"       "$D/sparse.v0"

# The lowest line has to win, and it has to win whichever chunk it lands
# in. Two different error kinds, the earlier one deep in chunk 0.
awk -v minb="$MIN" 'BEGIN {
    n = int(minb / 13) + 20000
    for (i = 0; i < n; i++) {
        print "mov rax, rbx"
        if (i == 300)        print "mov rax, [rbx@]"   # bad operand, earlier
        if (i % 4000 == 100) print "zzbad" i           # unknown mnemonic
    }
    print "mov rax, 60"; print "mov rdi, 0"; print "syscall"
}' > "$D/mixed.v0"
check "lowest line wins across error kinds" "$D/mixed.v0"

# A failed parallel build must not leave a partial output behind either.
rm -f "$D/leftover"
$V "$D/every.v0" "$D/leftover" 16 2>/dev/null >/dev/null
if [ -s "$D/leftover" ]; then
    echo "FAIL: a failed -j16 build left a non-empty output file"; fail=1
else
    echo "ok   no output file left behind by a failed parallel build"
fi

[ $fail -eq 0 ] && echo "PAR DIAG OK"
exit $fail
