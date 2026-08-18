#!/usr/bin/env bash
# run_difftest.sh -- differential test: assemble the same instruction
# sequence with our assembler and with an independent reference
# assembler, then compare the code bytes.
#
# The reference is GNU as (the project spec accepts NASM or GAS); its
# .text section is extracted with objcopy so no headers or layout
# assumptions enter the comparison. nasm is used instead when present,
# for the seed test, whose reference predates the GAS conversion.
#
# Each source/reference pair is written one instruction per line in
# lockstep, so a mismatch at byte N points at roughly the Nth
# instruction in both files.
#
# Immediates, displacements and jump distances are deliberately chosen
# so the reference cannot pick a shorter encoding than ours (no imm8, no
# disp8, no rel8, no accumulator-specific opcodes). Byte-identical output
# under those constraints is the correctness signal; it does not claim
# our encoder is as compact as a mature one for arbitrary input.
cd "$(dirname "$0")/.."
status=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- v1 against GNU as ---
if command -v as >/dev/null 2>&1 && command -v objcopy >/dev/null 2>&1; then
    if [ -x ./v1 ]; then
        as -o "$tmp/ref.o" tests/v1difftest_ref.s 2>"$tmp/as.err"
        if [ $? -ne 0 ]; then
            echo "run_difftest: as failed:" >&2; cat "$tmp/as.err" >&2; status=1
        else
            objcopy -O binary --only-section=.text "$tmp/ref.o" "$tmp/ref.bin"
            ./v1 tests/v1difftest.v0 "$tmp/v1.bin" 2>"$tmp/v1.err"
            if [ $? -ne 0 ]; then
                echo "run_difftest: v1 failed:" >&2; cat "$tmp/v1.err" >&2; status=1
            else
                n=$(wc -c < "$tmp/ref.bin")
                tail -c +233 "$tmp/v1.bin" | head -c "$n" > "$tmp/v1.code.bin"
                if cmp -s "$tmp/v1.code.bin" "$tmp/ref.bin"; then
                    echo "PASS: v1 matches GNU as byte-for-byte ($n bytes)"
                else
                    echo "FAIL: v1 differs from GNU as" >&2
                    cmp -l "$tmp/v1.code.bin" "$tmp/ref.bin" | head -8 >&2
                    echo "  (ours / reference, byte offsets are 1-based)" >&2
                    status=1
                fi
            fi
        fi
    fi
else
    echo "skipped v1: GNU as/objcopy not installed"
fi

# --- seed against nasm, if nasm happens to be available ---
if command -v nasm >/dev/null 2>&1 && [ -x ./seed/seed ]; then
    nasm -f bin tests/difftest_ref.asm -o "$tmp/snasm.bin" 2>"$tmp/n.err"
    if [ $? -ne 0 ]; then
        echo "run_difftest: nasm failed:" >&2; cat "$tmp/n.err" >&2; status=1
    else
        ./seed/seed < tests/difftest.v0 > "$tmp/seed.bin" 2>"$tmp/s.err"
        n=$(wc -c < "$tmp/snasm.bin")
        tail -c +121 "$tmp/seed.bin" | head -c "$n" > "$tmp/seed.code.bin"
        if cmp -s "$tmp/seed.code.bin" "$tmp/snasm.bin"; then
            echo "PASS: seed matches nasm byte-for-byte ($n bytes)"
        else
            echo "FAIL: seed differs from nasm" >&2; status=1
        fi
    fi
else
    echo "skipped seed: nasm not installed (seed is archived; v1 is the live check)"
fi

exit $status
