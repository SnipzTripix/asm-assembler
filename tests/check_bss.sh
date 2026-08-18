#!/usr/bin/env bash
# check_bss.sh -- .bss reserves zero-filled memory with no file cost.
cd "$(dirname "$0")/.."
V=${1:-./v1}
fail=0
$V tests/bss.v0 /tmp/bss.bin || { echo "assembly failed"; exit 1; }
/tmp/bss.bin
rc=$?
sz=$(wc -c < /tmp/bss.bin)
if [ $rc -eq 42 ]; then
    echo "ok   .bss zero-filled, writable, readable (exit 42)"
else
    echo "FAIL .bss: exit $rc, wanted 42"
    fail=1
fi
# 1 MiB reserved must not appear in the file
if [ "$sz" -lt 65536 ]; then
    echo "ok   1 MiB reserved costs nothing on disk (file is $sz bytes)"
else
    echo "FAIL .bss bytes leaked into the file ($sz bytes)"
    fail=1
fi
# resb outside .bss is an error, not a different meaning
printf '.text\nresb 16\n' > /tmp/badresb.v0
$V /tmp/badresb.v0 /tmp/x.bin 2>/tmp/badresb.err
[ $? -ne 0 ] && echo "ok   resb outside .bss rejected: $(cat /tmp/badresb.err)" \
             || { echo "FAIL resb allowed outside .bss"; fail=1; }
$V tests/bss.v0 /tmp/bss_p.bin 8 || exit 1
cmp -s /tmp/bss.bin /tmp/bss_p.bin && echo "ok   identical under -j8" \
     || { echo "FAIL differs under -j8"; fail=1; }
rm -f /tmp/bss.bin /tmp/bss_p.bin /tmp/badresb.v0 /tmp/badresb.err /tmp/x.bin
exit $fail
