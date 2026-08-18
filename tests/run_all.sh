#!/usr/bin/env bash
# run_all.sh -- the whole test suite. Usage: run_all.sh [assembler]
#
#   1. every tests/*.v0 program that is meant to run: assemble, execute,
#      check its exit status against the value it is supposed to return
#   2. the range/overflow regressions (tests/regress_range.sh)
#   3. the self-hosting fixed point (tests/fixedpoint.sh)
#   4. the nasm differential test, if nasm is installed (tests/run_difftest.sh)
cd "$(dirname "$0")/.."
V=${1:-./v1}
fail=0

# name:expected_exit -- programs whose exit status is the assertion
run_prog() {
    local name="$1" want="$2"
    $V "tests/$name.v0" "/tmp/rt_$name" 2>"/tmp/rt_$name.err"
    if [ $? -ne 0 ]; then
        echo "FAIL $name: assembly error: $(cat /tmp/rt_$name.err)"
        fail=1
        return
    fi
    out=$("/tmp/rt_$name")
    got=$?
    if [ "$got" = "$want" ]; then
        echo "ok   $name (exit $got)${out:+ out=[$out]}"
    else
        echo "FAIL $name: exit $got, wanted $want"
        fail=1
    fi
    rm -f "/tmp/rt_$name" "/tmp/rt_$name.err"
}

echo "=== programs ==="
run_prog hello    0
run_prog edge     7
run_prog sections 0

echo "=== data directives (dw/dd/dq, dq-label jump table) ==="
./tests/check_data_dirs.sh "$V" || fail=1

echo "=== function-pointer dispatch (dq label + call reg) ==="
./tests/check_dispatch.sh "$V" || fail=1

echo "=== db string escapes ==="
./tests/check_escapes.sh "$V" || fail=1

echo "=== scaled-index addressing ==="
./tests/check_scaled.sh "$V" || fail=1

echo "=== .bss / resb ==="
./tests/check_bss.sh "$V" || fail=1

echo "=== range / overflow regressions ==="
./tests/regress_range.sh "$V"

echo "=== parallel == serial (byte-for-byte, every worker count) ==="
./tests/par_equiv.sh "$V" | tail -3
./tests/par_equiv.sh "$V" >/dev/null 2>&1 || fail=1

echo "=== parallel determinism ==="
./tests/determinism.sh "$V" v1.v0 8 4

echo "=== cross-chunk references ==="
./tests/repro_cross.sh "$V" 400

echo "=== self-hosting fixed point ==="
./tests/fixedpoint.sh "$V" || fail=1

echo "=== differential vs an independent assembler ==="
./tests/run_difftest.sh || fail=1

echo
if [ $fail -eq 0 ]; then
    echo "ALL PASS"
else
    echo "FAILURES ABOVE"
fi
exit $fail
