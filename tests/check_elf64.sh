#!/usr/bin/env bash
# check_elf64.sh -- object output that the rest of the toolchain accepts.
#
# The point of -f elf64 is not that readelf can parse the file; it is
# that ld can link it, against objects v1 did not produce, and that the
# result runs. Every case here goes all the way through to a running
# program or a linker diagnostic. Skipped, not failed, when binutils is
# absent -- v1 itself needs no toolchain.
cd "$(dirname "$0")/.."
V=${1:-./v1}
command -v ld >/dev/null 2>&1 || { echo "SKIP: ld not installed"; exit 0; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

# --- two objects, a call across the boundary, and data in each ---
cat > "$D/a.v0" <<'EOF'
global _start
extern add_seven
extern shared_msg
.text
_start:
call add_seven
mov rsi, shared_msg
mov rdx, 6
mov rdi, 1
mov rax, 1
syscall
mov rdi, rbx
mov rax, 60
syscall
EOF

cat > "$D/b.v0" <<'EOF'
global add_seven
global shared_msg
.text
add_seven:
mov rbx, 7
ret
.data
shared_msg:
db "linked"
EOF

$V -f elf64 "$D/a.v0" "$D/a.o" 2>"$D/e" || { echo "FAIL: assembling a.v0: $(cat "$D/e")"; exit 1; }
$V -f elf64 "$D/b.v0" "$D/b.o" 2>"$D/e" || { echo "FAIL: assembling b.v0: $(cat "$D/e")"; exit 1; }

if ld -o "$D/prog" "$D/a.o" "$D/b.o" 2>"$D/e"; then
    out=$("$D/prog"); rc=$?
    [ "$rc" = 7 ] && [ "$out" = "linked" ] \
        && echo "ok   linked two objects, ran: exit $rc, stdout [$out]" \
        || { echo "FAIL: exit $rc stdout [$out], wanted 7 and [linked]"; fail=1; }
else
    echo "FAIL: ld rejected the objects: $(cat "$D/e")"; fail=1
fi

# --- linking against an object from a different assembler ---
if command -v as >/dev/null 2>&1; then
    cat > "$D/c.s" <<'EOF'
.intel_syntax noprefix
.globl add_seven
.globl shared_msg
.text
add_seven:
mov rbx, 7
ret
.data
shared_msg:
.ascii "linked"
EOF
    as -o "$D/c.o" "$D/c.s" 2>/dev/null
    if ld -o "$D/prog2" "$D/a.o" "$D/c.o" 2>"$D/e"; then
        out=$("$D/prog2"); rc=$?
        [ "$rc" = 7 ] && [ "$out" = "linked" ] \
            && echo "ok   v1 object linked against a GNU as object" \
            || { echo "FAIL: mixed link ran wrong: exit $rc [$out]"; fail=1; }
    else
        echo "FAIL: ld rejected the mixed link: $(cat "$D/e")"; fail=1
    fi
fi

# --- an undefined symbol must be the linker's complaint, not silence ---
cat > "$D/d.v0" <<'EOF'
global _start
extern never_defined
_start:
call never_defined
ret
EOF
$V -f elf64 "$D/d.v0" "$D/d.o" 2>"$D/e" || { echo "FAIL: assembling d.v0: $(cat "$D/e")"; fail=1; }
if ld -o "$D/prog3" "$D/d.o" 2>"$D/e"; then
    echo "FAIL: ld accepted a link with never_defined missing"; fail=1
else
    grep -q 'never_defined' "$D/e" \
        && echo "ok   ld names the undefined symbol" \
        || { echo "FAIL: ld failed without naming it: $(cat "$D/e")"; fail=1; }
fi

# --- a reference to a name that was never declared extern is OUR error ---
printf 'call nowhere\nret\n' > "$D/e.v0"
if $V -f elf64 "$D/e.v0" "$D/e.o" 2>"$D/e"; then
    echo "FAIL: accepted a reference to an undeclared name"; fail=1
else
    grep -q 'nowhere' "$D/e" \
        && echo "ok   undeclared name rejected: $(cat "$D/e")" \
        || { echo "FAIL: rejected without naming it: $(cat "$D/e")"; fail=1; }
fi

# --- nm agrees about what is global and what is local ---
cat > "$D/f.v0" <<'EOF'
global visible
visible:
hidden:
ret
EOF
$V -f elf64 "$D/f.v0" "$D/f.o" 2>"$D/e" || { echo "FAIL: assembling f.v0"; fail=1; }
if command -v nm >/dev/null 2>&1; then
    nm "$D/f.o" | grep -q '^0*0 T visible' \
        && echo "ok   nm reports visible as a global text symbol" \
        || { echo "FAIL: nm output: $(nm "$D/f.o" | tr '\n' ' ')"; fail=1; }
    nm "$D/f.o" | grep -q ' t hidden' \
        && echo "ok   nm reports hidden as local" \
        || { echo "FAIL: hidden is not local: $(nm "$D/f.o" | tr '\n' ' ')"; fail=1; }
fi

# --- the whole assembler, as an object, linked by ld, still self-hosts ---
# This is the fixed point routed through somebody else's linker: if the
# symbol table, the relocations or the section layout were wrong in any
# way that mattered, the linked binary would not reproduce v1's own
# output byte for byte.
$V -f elf64 v1.v0 "$D/v1.o" 2>"$D/e" || { echo "FAIL: -f elf64 on v1.v0: $(cat "$D/e")"; exit 1; }
if ld -e start -o "$D/v1_linked" "$D/v1.o" 2>"$D/e"; then
    if "$D/v1_linked" v1.v0 "$D/v1_out" 2>"$D/e"; then
        cmp -s "$D/v1_out" "$V" \
            && echo "ok   v1 linked by ld reproduces v1's own output exactly" \
            || { echo "FAIL: the ld-linked assembler produced a different binary"; fail=1; }
    else
        echo "FAIL: the ld-linked assembler did not run: $(cat "$D/e")"; fail=1
    fi
else
    echo "FAIL: ld could not link v1.o: $(cat "$D/e")"; fail=1
fi

exit $fail
