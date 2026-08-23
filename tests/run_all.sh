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

# First, and on its own: the invocation everything below depends on.
# Every other test here runs `$V file.v0 file.out`, so when that shape
# broke, the failure arrived as dozens of unrelated-looking FAILs with no
# indication of the common cause.
echo "=== smoke: the documented invocations ==="
./tests/safe.sh ./tests/check_smoke.sh "$V" || fail=1

echo "=== memory layout constants do not overlap ==="
./tests/safe.sh ./tests/check_layout.sh || fail=1

echo "=== programs ==="
run_prog hello    0
run_prog edge     7
run_prog sections 0

echo "=== data directives (dw/dd/dq, dq-label jump table) ==="
./tests/safe.sh ./tests/check_data_dirs.sh "$V" || fail=1

echo "=== function-pointer dispatch (dq label + call reg) ==="
./tests/safe.sh ./tests/check_dispatch.sh "$V" || fail=1

echo "=== db string escapes ==="
./tests/safe.sh ./tests/check_escapes.sh "$V" || fail=1

echo "=== scaled-index addressing ==="
./tests/safe.sh ./tests/check_scaled.sh "$V" || fail=1

echo "=== .bss / resb ==="
./tests/safe.sh ./tests/check_bss.sh "$V" || fail=1

echo "=== %include ==="
./tests/safe.sh ./tests/check_include.sh "$V" || fail=1

echo "=== review regressions ==="
./tests/safe.sh ./tests/check_review.sh "$V" || fail=1

echo "=== -f elf64 object output ==="
./tests/safe.sh ./tests/check_elf64.sh "$V" || fail=1

echo "=== a worker count never breaks a build ==="
./tests/safe.sh ./tests/check_par_fallback.sh "$V" || fail=1

echo "=== symbol tables near their limits, at every worker count ==="
./tests/safe.sh ./tests/check_saturation.sh "$V" || fail=1

echo "=== equ aliases resolve the same in both paths ==="
./tests/safe.sh ./tests/check_equ_par.sh "$V" || fail=1

echo "=== input that must be rejected ==="
./tests/safe.sh ./tests/check_reject.sh "$V" || fail=1

echo "=== range / overflow regressions ==="
./tests/safe.sh ./tests/regress_range.sh "$V" || fail=1

echo "=== parallel == serial (byte-for-byte, every worker count) ==="
./tests/safe.sh ./tests/par_equiv.sh "$V" > /tmp/ra_par.log 2>&1 || fail=1
tail -3 /tmp/ra_par.log; rm -f /tmp/ra_par.log   # it builds a 3.8MB input
                                                 # and times it; running it
                                                 # twice to get both the
                                                 # output and the status
                                                 # doubled that for nothing

echo "=== parallel determinism ==="
./tests/safe.sh ./tests/determinism.sh "$V" v1.v0 8 4 || fail=1

echo "=== cross-chunk references ==="
./tests/safe.sh ./tests/repro_cross.sh "$V" 400 || fail=1

echo "=== self-hosting fixed point ==="
./tests/safe.sh ./tests/fixedpoint.sh "$V" || fail=1

echo "=== differential vs an independent assembler ==="
./tests/safe.sh ./tests/run_difftest.sh || fail=1

echo "=== exhaustive differential (generated cross product) ==="
./tests/safe.sh ./tests/gen_difftest.sh "$V" || fail=1

echo
if [ $fail -eq 0 ]; then
    echo "ALL PASS"
else
    echo "FAILURES ABOVE"
fi
exit $fail
