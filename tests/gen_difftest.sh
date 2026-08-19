#!/usr/bin/env bash
# gen_difftest.sh -- generate an exhaustive differential test and run it.
#
# The hand-written difftest covers ~600 bytes. This emits the full cross
# product instead -- every ALU op against all 16x16 register pairs, every
# memory form across all bases and indices and scales, every unary form
# across all 16 registers, and immediate boundary values -- assembles it
# with both v1 and GNU as, and compares.
#
# Values are chosen so the reference cannot pick a shorter encoding than
# ours: displacements and immediates are outside imm8/disp8 range, and no
# accumulator-specific opcode applies. Where our encoder is deliberately
# non-minimal in a way the reference is not, the form is skipped and
# named here rather than silently omitted:
#
#   * jumps: we always emit rel32, as the single-pass design requires.
#
# Displacements used to be on that list. They are not any more: a
# displacement is a constant known at emit time, so picking disp0/disp8
# moves nothing, and the boundary block below tests exactly that choice
# against the reference -- 0, +-127, +-128, and the first value that
# must widen to disp32, across every base, with and without an index.
# Those are the cases where mod bits and the rbp/r13 and rsp/r12 escapes
# interact, which is where an encoder gets it wrong.
set -u
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

REGS="rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15"
# rsp cannot be a SIB index; every other register can
IDXREGS="rax rcx rdx rbx rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15"

v0="$D/gen.v0"; ref="$D/gen.s"
: > "$v0"
{ echo '.intel_syntax noprefix'; echo '.text'; } > "$ref"

emit() { echo "$1" >> "$v0"; echo "	$2" >> "$ref"; }

# --- ALU reg,reg over the full 16x16 cross product ---
for op in add sub and or xor cmp test imul; do
    for d in $REGS; do for s in $REGS; do
        emit "$op $d, $s" "$op $d, $s"
    done; done
done

# --- ALU reg,imm32 (values too wide for imm8; rax excluded where the
#     reference would use the accumulator-specific opcode) ---
for op in add sub and or xor cmp test imul; do
    for d in $REGS; do
        [ "$d" = "rax" ] && continue
        emit "$op $d, 123456" "$op $d, 123456"
        emit "$op $d, -654321" "$op $d, -654321"
    done
done

# --- ALU reg,imm8: the 83 /digit form, for every register including rax
#     (the accumulator short opcode only exists at imm32, so there is no
#     collision here the way there is above) ---
for op in add sub and or xor cmp; do
    for d in $REGS; do
        for v in 0 1 127 -1 -128; do
            emit "$op $d, $v" "$op $d, $v"
        done
    done
done
# 128 and -129 are the first values on each side that must widen to
# imm32; rax excluded again, where the reference takes the short opcode.
for op in add sub and or xor cmp; do
    for d in $REGS; do
        [ "$d" = "rax" ] && continue
        emit "$op $d, 128" "$op $d, 128"
        emit "$op $d, -129" "$op $d, -129"
    done
done

# --- mov reg,imm: three encodings by magnitude ---
# A value that fits unsigned 32 bits goes in the five-byte B8+r form,
# because writing a 32-bit register zero-extends into the full 64. GNU as
# spells that `mov eax, 1` and reserves `mov rax, 1` for the seven-byte
# sign-extended C7 form, so the reference side names the 32-bit register
# -- same architectural effect, and the bytes have to match exactly.
r32() { case $1 in
    rax) echo eax;; rcx) echo ecx;; rdx) echo edx;; rbx) echo ebx;;
    rsp) echo esp;; rbp) echo ebp;; rsi) echo esi;; rdi) echo edi;;
    *) echo "${1}d";; esac; }
for d in $REGS; do
    e=$(r32 "$d")
    for v in 0 1 255 65535 0x7fffffff 0xffffffff; do
        emit "mov $d, $v" "mov $e, $v"
    done
    emit "mov $d, -1"           "mov $d, -1"
    emit "mov $d, -2147483648"  "mov $d, -2147483648"
    emit "mov $d, 4294967296"   "movabs $d, 4294967296"
    emit "mov $d, -2147483649"  "movabs $d, -2147483649"
done

# --- Jcc rel32, every condition ---
# Jumps were exempt from this test because we always emit rel32 while the
# reference shortens to rel8 whenever it can. That exemption hid the
# opcode byte, which is the part worth checking. Putting each target
# beyond rel8 range removes the reference's choice: 132 bytes of padding
# after each jump means both assemblers must use rel32, and then the
# bytes have to agree.
n=0
for c in o no b ae e ne be a s ns p np l ge le g; do
    n=$((n+1))
    emit "j$c Lj$n" "j$c Lj$n"
    for _ in $(seq 132); do emit "db 0x90" ".byte 0x90"; done
    emit "Lj$n:" "Lj$n:"
done

# --- unary forms ---
for d in $REGS; do
    emit "neg $d"    "neg $d"
    emit "push $d"   "push $d"
    emit "pop $d"    "pop $d"
    emit "call $d"   "call $d"
    emit "shl $d, 7" "shl $d, 7"
    emit "shr $d, 9" "shr $d, 9"
    emit "mov $d, 0x123456789ABCDEF0" "movabs $d, 0x123456789ABCDEF0"
done

# --- memory: [base+disp32] for every base, load and store ---
for b in $REGS; do
    emit "mov rcx, [$b+4096]"  "mov rcx, [$b+4096]"
    emit "mov [$b+4096], rcx"  "mov [$b+4096], rcx"
    emit "lea rdx, [$b+8192]"  "lea rdx, [$b+8192]"
    emit "movb rsi, [$b+300]"  "movzx rsi, byte ptr [$b+300]"
    emit "movw rsi, [$b+300]"  "movzx rsi, word ptr [$b+300]"
    emit "movd rsi, [$b+300]"  "mov esi, dword ptr [$b+300]"
    emit "movb [$b+300], r9"   "mov byte ptr [$b+300], r9b"
    emit "movw [$b+300], r9"   "mov word ptr [$b+300], r9w"
    emit "movd [$b+300], r9"   "mov dword ptr [$b+300], r9d"
done

# --- memory: [base+index*scale+disp32], all bases x indices x scales ---
for b in $REGS; do
    for x in $IDXREGS; do
        for sc in 1 2 4 8; do
            emit "mov rax, [$b+$x*$sc+512]" "mov rax, [$b+$x*$sc+512]"
        done
    done
done

# --- displacement boundaries: the disp0 / disp8 / disp32 decision ---
# rbp and r13 are the interesting bases: mod=00 with rm=101 means
# RIP-relative, and in the SIB form it means "no base", so a zero offset
# on those two must still be encoded as a disp8 of zero. rsp and r12
# force a SIB byte regardless. GNU as makes the same choices, so any
# disagreement here is ours.
# A negative offset is written [base-N], never [base+-N]: the dialect
# takes one sign, and the reference accepting both is not a reason to
# generate a form v1 is right to reject.
signed() { case $1 in -*) printf '%s' "$1" ;; *) printf '+%s' "$1" ;; esac; }

for b in $REGS; do
    for d in 0 1 127 128 -1 -128 -129 255 -32768; do
        o=$(signed "$d")
        emit "mov rcx, [$b$o]" "mov rcx, [$b$o]"
        emit "mov [$b$o], rcx" "mov [$b$o], rcx"
        emit "lea rdx, [$b$o]" "lea rdx, [$b$o]"
    done
done
for b in $REGS; do
    for x in rax rbp r12 r13; do
        for d in 0 127 128 -128 -129; do
            o=$(signed "$d")
            emit "mov rax, [$b+$x*4$o]" "mov rax, [$b+$x*4$o]"
        done
    done
done

echo "generated $(wc -l < "$v0") instructions"

$V "$v0" "$D/v1.bin" 2>"$D/v1.err" || { echo "v1 FAILED: $(head -2 "$D/v1.err")"; exit 1; }
as -o "$D/ref.o" "$ref" 2>"$D/as.err"  || { echo "as FAILED: $(head -3 "$D/as.err")"; exit 1; }
objcopy -O binary --only-section=.text "$D/ref.o" "$D/ref.bin"

n=$(wc -c < "$D/ref.bin")
tail -c +289 "$D/v1.bin" | head -c "$n" > "$D/v1.code.bin"
if cmp -s "$D/v1.code.bin" "$D/ref.bin"; then
    echo "PASS: $n bytes identical to GNU as across the full cross product"
    exit 0
fi
echo "FAIL: differs from GNU as" >&2
cmp -l "$D/v1.code.bin" "$D/ref.bin" | head -10 >&2
echo "  (first differing byte offsets, 1-based; ours / reference)" >&2
exit 1
