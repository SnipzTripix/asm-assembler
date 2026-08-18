#!/usr/bin/env bash
# check_dispatch.sh -- `dq label` table + `call reg` indirect dispatch.
cd "$(dirname "$0")/.."
V=${1:-./v1}
$V tests/dispatch.v0 /tmp/disp.bin || { echo "assembly failed"; exit 1; }
/tmp/disp.bin
rc=$?
if [ $rc -eq 42 ]; then
    echo "ok   function-pointer dispatch (exit 42)"
else
    echo "FAIL dispatch: exit $rc, wanted 42"
fi
$V tests/dispatch.v0 /tmp/disp_p.bin 8 || exit 1
cmp -s /tmp/disp.bin /tmp/disp_p.bin && echo "ok   identical under -j8" || echo "FAIL differs under -j8"
rm -f /tmp/disp.bin /tmp/disp_p.bin
[ $rc -eq 42 ]
