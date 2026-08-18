#!/usr/bin/env bash
# check_scaled.sh -- [base+index*scale+disp] addressing at runtime.
cd "$(dirname "$0")/.."
V=${1:-./v1}
$V tests/scaled.v0 /tmp/sc.bin || { echo "assembly failed"; exit 1; }
/tmp/sc.bin
rc=$?
if [ $rc -eq 100 ]; then
    echo "ok   scaled-index addressing (sum 100)"
else
    echo "FAIL scaled-index: exit $rc, wanted 100 (1 = byte load wrong)"
fi
$V tests/scaled.v0 /tmp/sc_p.bin 8 || exit 1
cmp -s /tmp/sc.bin /tmp/sc_p.bin && echo "ok   identical under -j8" || echo "FAIL differs under -j8"

# rsp as an index, and a bad scale, must both be rejected cleanly
printf 'mov rax, [rbx+rsp*8+0]\n' > /tmp/badidx.v0
$V /tmp/badidx.v0 /tmp/x.bin 2>/tmp/badidx.err
[ $? -ne 0 ] && echo "ok   rsp index rejected: $(cat /tmp/badidx.err)" || echo "FAIL rsp index allowed"
printf 'mov rax, [rbx+rcx*3+0]\n' > /tmp/badsc.v0
$V /tmp/badsc.v0 /tmp/x.bin 2>/tmp/badsc.err
[ $? -ne 0 ] && echo "ok   bad scale rejected: $(cat /tmp/badsc.err)" || echo "FAIL bad scale allowed"

rm -f /tmp/sc.bin /tmp/sc_p.bin /tmp/badidx.v0 /tmp/badsc.v0 /tmp/x.bin /tmp/badidx.err /tmp/badsc.err
[ $rc -eq 100 ]
