#!/usr/bin/env bash
# par_equiv.sh -- the correctness oracle for parallel assembly: for every
# test input, and every worker count, the output must be byte-identical
# to what the serial path produces. Parallelism is only allowed to make
# it faster, never different.
#   usage: par_equiv.sh [assembler]
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(dirname "$0")
fail=0

for src in tests/hello.v0 tests/edge.v0 tests/sections.v0 v1.v0; do
    "$D/safe.sh" "$V" "$src" /tmp/pe_ser 1 2>/tmp/pe_ser.err
    if [ $? -ne 0 ]; then
        echo "FAIL $src: serial assembly failed: $(cat /tmp/pe_ser.err)"
        fail=1
        continue
    fi
    for j in 2 3 4 8 16; do
        "$D/safe.sh" "$V" "$src" /tmp/pe_par "$j" 2>/tmp/pe_par.err
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "FAIL $src -j$j: rc=$rc $(cat /tmp/pe_par.err)"
            fail=1
            continue
        fi
        if cmp -s /tmp/pe_ser /tmp/pe_par; then
            echo "ok   $src -j$j  identical to serial"
        else
            echo "FAIL $src -j$j  DIFFERS from serial"
            cmp /tmp/pe_ser /tmp/pe_par | head -2
            fail=1
        fi
    done
done

rm -f /tmp/pe_ser /tmp/pe_par /tmp/pe_ser.err /tmp/pe_par.err
if [ $fail -eq 0 ]; then echo "PAR EQUIV OK"; else echo "PAR EQUIV FAILURES"; fi
exit $fail
