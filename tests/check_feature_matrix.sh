#!/usr/bin/env bash
# check_feature_matrix.sh -- every feature, past the parallel threshold,
# at several worker counts.
#
# The suite is strong on each feature and strong on each invariant. Both
# bugs found recently lived in the *product* of two features that were
# each well covered on their own: .bss x parallel, and the size threshold
# x parallel. Nothing constructed the combination, so nothing ran it.
#
# This is that combination, made cheap: take a source that exercises one
# feature and produces a known exit status, pad it past PAR_MIN_BYTES so
# the parallel path is actually taken, and assert three things -- the
# output is byte-identical at every worker count, the program still
# produces its answer, and the segment count matches serial. A feature
# that only works below the threshold fails here.
#
# Adding a feature means adding a case. That is the whole maintenance
# cost, and it is less than either of the bugs above cost.
set -u
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

# Read the threshold out of the source: hardcoding it is how a test
# quietly stops testing the thing it was written for.
MIN=$(grep -m1 '^PAR_MIN_BYTES' v1.v0 | awk '{print $3}')
[ -n "$MIN" ] || { echo "FAIL: could not read PAR_MIN_BYTES from v1.v0"; exit 1; }

# @PAD@ becomes enough filler statements to clear the threshold. rbx is
# the filler's register precisely because no case below uses it.
expand() { # expand <src-with-@PAD@> <out>
    awk -v minb="$MIN" '
        /^@PAD@$/ { for (i = 0; i < int(minb / 11) + 8000; i++)
                        print "mov rbx, " (i % 97)
                    next }
        { print }' "$1" > "$2"
}

check() { # check <name> <wanted-exit> <src-file>
    local name="$1" want="$2" src="$3"
    expand "$src" "$D/in.v0"
    local sz; sz=$(wc -c < "$D/in.v0")
    if [ "$sz" -lt "$MIN" ]; then
        echo "FAIL $name: ${sz}B is under PAR_MIN_BYTES ($MIN) -- this case"
        echo "     would run serially and assert nothing"; fail=1; return
    fi
    if ! $V "$D/in.v0" "$D/j1" 1 2>"$D/e"; then
        echo "FAIL $name: serial assembly failed: $(head -1 "$D/e")"
        fail=1; return
    fi
    local bad=""
    for j in 2 3 5 8 16; do
        if ! $V "$D/in.v0" "$D/j$j" "$j" 2>"$D/e"; then
            bad="$bad -j$j($(head -1 "$D/e"))"; continue
        fi
        cmp -s "$D/j1" "$D/j$j" || bad="$bad -j$j(differs)"
        if command -v readelf >/dev/null 2>&1; then
            local a b
            a=$(readelf -l "$D/j1"  2>/dev/null | grep -c 'LOAD')
            b=$(readelf -l "$D/j$j" 2>/dev/null | grep -c 'LOAD')
            [ "$a" = "$b" ] || bad="$bad -j$j($a vs $b LOAD)"
        fi
    done
    if [ -n "$bad" ]; then
        echo "FAIL $name:$bad"; fail=1; return
    fi
    # Byte-identical is not enough on its own: if every path dropped the
    # same segment the comparison would still pass. Run it.
    chmod +x "$D/j1" "$D/j16"
    "$D/j1"  >/dev/null 2>&1; local s=$?
    "$D/j16" >/dev/null 2>&1; local p=$?
    if [ "$s" != "$want" ] || [ "$p" != "$want" ]; then
        echo "FAIL $name: exit serial=$s parallel=$p, wanted $want"
        fail=1; return
    fi
    echo "ok   $name (${sz}B, identical at -j1..16, exit $want, segments match)"
}

# --- the cases. Each leaves its answer in rdi and exits with it. ---

#
# Sections are declared BEFORE the padding, not after. That is not a
# style choice: a .data or .bss block written at the end of the file
# lands in the last chunk, and the parallel .bss bug was invisible in
# exactly that position -- the worker's bogus data size tripped the slot
# cap, the parent fell back to serial, and the output came out right by
# accident. Written first, the section is real for every worker. An
# earlier draft of this file put them last and passed against the broken
# binary. tests/check_bss_par.sh owns the position axis on purpose.

cat > "$D/data.v0" <<'EOF'
.data
val: dq 11
.text
mov rax, val
mov rdi, [rax+0]
@PAD@
mov rax, 60
syscall
EOF
check "data: dq + label address" 11 "$D/data.v0"

cat > "$D/bss.v0" <<'EOF'
.bss
buf: resb 4096
.text
mov rax, buf
mov rcx, 12
mov [rax+0], rcx
mov rdi, [rax+0]
@PAD@
mov rax, 60
syscall
EOF
check "bss: resb + store + load" 12 "$D/bss.v0"

cat > "$D/both.v0" <<'EOF'
.data
dv: dq 13
.bss
buf: resb 64
.text
mov rax, dv
mov rcx, [rax+0]
mov rax, buf
mov [rax+0], rcx
mov rdi, [rax+0]
@PAD@
mov rax, 60
syscall
EOF
check "bss + data together" 13 "$D/both.v0"

cat > "$D/disp.v0" <<'EOF'
.data
tbl: dq one
dq two
.text
mov rax, tbl
mov rcx, [rax+8]
call rcx
@PAD@
mov rax, 60
syscall
two:
mov rdi, 14
ret
one:
mov rdi, 99
ret
EOF
check "dq label + call reg dispatch" 14 "$D/disp.v0"

cat > "$D/jmpreg.v0" <<'EOF'
mov rax, tgt
jmp rax
mov rdi, 99
mov rax, 60
syscall
tgt:
mov rdi, 15
@PAD@
mov rax, 60
syscall
EOF
check "jmp reg" 15 "$D/jmpreg.v0"

cat > "$D/scaled.v0" <<'EOF'
.data
arr: dq 0
dq 0
dq 16
.text
mov rax, arr
mov rcx, 2
mov rdi, [rax+rcx*8+0]
@PAD@
mov rax, 60
syscall
EOF
check "scaled index into .data" 16 "$D/scaled.v0"

cat > "$D/equ.v0" <<'EOF'
A equ 9
B equ A
mov rdi, B
add rdi, 8
@PAD@
mov rax, 60
syscall
EOF
check "equ alias resolved across chunks" 17 "$D/equ.v0"

cat > "$D/jcc.v0" <<'EOF'
mov rcx, 1
cmp rcx, 1
je fwd
mov rdi, 99
mov rax, 60
syscall
fwd:
mov rdi, 18
@PAD@
cmp rdi, 18
jne bad
mov rax, 60
syscall
bad:
mov rdi, 99
mov rax, 60
syscall
EOF
check "Jcc across a padded chunk boundary" 18 "$D/jcc.v0"

cat > "$D/str.v0" <<'EOF'
.data
s: db "a\nb"
.text
mov rax, s
movb rdi, [rax+1]
add rdi, 9                       ; the escape puts a newline (10) at [1]
@PAD@
mov rax, 60
syscall
EOF
check "db string with escapes" 19 "$D/str.v0"

cat > "$D/mixed.v0" <<'EOF'
.data
dv: dq 19
.bss
buf: resb 32
.text
mov rax, dv
mov rcx, [rax+0]
mov rax, buf
mov [rax+0], rcx
call bump
mov rdi, [rax+0]
@PAD@
mov rax, 60
syscall
bump:
mov rdx, buf
mov rcx, [rdx+0]
add rcx, 1
mov [rdx+0], rcx
ret
EOF
check "call across chunks touching .data and .bss" 20 "$D/mixed.v0"

[ $fail -eq 0 ] && echo "FEATURE MATRIX OK"
exit $fail
