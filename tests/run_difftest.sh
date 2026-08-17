#!/usr/bin/env bash
# run_difftest.sh -- differential test: assemble our .v0 sources with our
# assembler(s) and the matching nasm .asm reference, compare code bytes.
#
#   v1 (top-level, the current canonical assembler) is checked against
#   tests/v1difftest.v0 -- the instruction set v1's dialect supports
#   (je/jne/jl/jae only, plus lea/imul which v1 has and seed doesn't).
#
#   seed/seed (retired bootstrap tool, kept for the historical record) is
#   checked against tests/difftest.v0 -- seed's larger jcc set (also
#   jge/jg/jle/jb/ja/jbe), no lea/imul.
#
# Each source/reference pair is written in lockstep, one instruction per
# line, so a byte mismatch at offset N points at roughly the Nth
# instruction in both files for easy triage.
#
# Immediate values, memory displacements, and jump distances are all
# deliberately chosen so nasm can't take one of its automatic shorter
# encodings (32-bit mov, disp8, imm8, accumulator-specific opcodes, rel8
# jumps) that our encoder never uses -- see the comments at the top of
# each _ref.asm file. Byte-identical output under those constraints is
# the real correctness signal; it does not mean our encoder is as
# compact as nasm's for arbitrary source (it deliberately isn't).
cd "$(dirname "$0")/.."

if ! command -v nasm >/dev/null 2>&1; then
    echo "run_difftest: nasm not found on PATH" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0

check_one() {
    local name="$1" bin="$2" v0="$3" ref="$4" hdr_len="$5"
    if [ ! -x "$bin" ]; then
        echo "run_difftest: $bin not found or not executable, skipping $name" >&2
        return
    fi

    nasm -f bin "$ref" -o "$tmp/$name.nasm.bin" 2>"$tmp/$name.nasm.err"
    if [ $? -ne 0 ]; then
        echo "run_difftest: nasm failed to assemble $ref:" >&2
        cat "$tmp/$name.nasm.err" >&2
        status=1
        return
    fi

    "$bin" < "$v0" > "$tmp/$name.bin" 2>"$tmp/$name.err"
    if [ $? -ne 0 ]; then
        echo "run_difftest: $name failed to assemble $v0:" >&2
        cat "$tmp/$name.err" >&2
        status=1
        return
    fi

    # Strip the ELF header, then compare only the first N bytes (N =
    # nasm's own output length): v1's output may have trailing
    # page-alignment padding before an (empty, in these tests) .data
    # PT_LOAD that nasm's raw -f bin output never has, so an exact
    # whole-file cmp would spuriously fail on that padding alone.
    n=$(wc -c < "$tmp/$name.nasm.bin")
    tail -c +$((hdr_len + 1)) "$tmp/$name.bin" | head -c "$n" > "$tmp/$name.code.bin"
    if cmp -s "$tmp/$name.code.bin" "$tmp/$name.nasm.bin"; then
        echo "PASS: $name's encoding matches nasm byte-for-byte ($n bytes)"
    else
        echo "FAIL: $name's encoding differs from nasm" >&2
        cmp "$tmp/$name.code.bin" "$tmp/$name.nasm.bin" >&2 || true
        status=1
    fi
}

check_one v1   ./v1        tests/v1difftest.v0 tests/v1difftest_ref.asm 176
check_one seed ./seed/seed tests/difftest.v0    tests/difftest_ref.asm  120

exit $status
