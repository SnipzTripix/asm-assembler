#!/usr/bin/env bash
# check_data_dirs.sh -- dw/dd/dq round-trip and dq-label jump table.
cd "$(dirname "$0")/.."
V=${1:-./v1}
$V tests/data_dirs.v0 /tmp/dd.bin || { echo "assembly failed"; exit 1; }
/tmp/dd.bin
rc=$?
if [ $rc -eq 42 ]; then
    echo "ok   data directives + dq jump table (exit 42)"
else
    echo "FAIL data directives: exit $rc (42=ok, 7=value mismatch, 99=wrong table entry)"
fi
# and the same source under parallel workers must be byte-identical
$V tests/data_dirs.v0 /tmp/dd_p.bin 8 || { echo "parallel assembly failed"; exit 1; }
cmp -s /tmp/dd.bin /tmp/dd_p.bin && echo "ok   identical under -j8" || echo "FAIL differs under -j8"
rm -f /tmp/dd.bin /tmp/dd_p.bin
[ $rc -eq 42 ]
