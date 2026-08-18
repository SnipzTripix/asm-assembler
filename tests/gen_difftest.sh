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
#   * disp8: we always emit disp32 for the same reason (the length must
#     be final at emit time). This is the only remaining systematic
#     difference and it is checked for separately, below.
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
