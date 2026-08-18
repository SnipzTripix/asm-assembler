#!/usr/bin/env bash
# check_escapes.sh -- db string escape sequences produce real bytes.
cd "$(dirname "$0")/.."
V=${1:-./v1}
fail=0
$V tests/escapes.v0 /tmp/esc.bin || { echo "assembly failed"; exit 1; }
/tmp/esc.bin > /tmp/esc.got
printf 'esc:\tX\nquote:" back:\\\n' > /tmp/esc.want
if cmp -s /tmp/esc.got /tmp/esc.want; then
    echo "ok   escapes \\t \\n \\\" \\\\ emit real bytes"
else
    echo "FAIL escapes"
    echo "  got : $(od -An -t x1 < /tmp/esc.got | tr -d '\n')"
    echo "  want: $(od -An -t x1 < /tmp/esc.want | tr -d '\n')"
    fail=1
fi
rm -f /tmp/esc.got /tmp/esc.want

# an unknown escape must be a clean error, not a silently kept backslash
printf 'db "bad\\q"\n' > /tmp/badesc.v0
$V /tmp/badesc.v0 /tmp/badesc.bin 2>/tmp/badesc.err
if [ $? -ne 0 ] && grep -q "escape" /tmp/badesc.err; then
    echo "ok   unknown escape rejected: $(cat /tmp/badesc.err)"
else
    echo "FAIL unknown escape not rejected"
    fail=1
fi
rm -f /tmp/esc.bin /tmp/badesc.v0 /tmp/badesc.bin /tmp/badesc.err
exit $fail
