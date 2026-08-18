#!/usr/bin/env bash
# fixedpoint.sh -- verify a candidate assembler reproduces itself.
# Usage: fixedpoint.sh [candidate]   (default ./v1)
#
# When the candidate was built by a PREVIOUS generation, comparing it
# against ./v1 proves nothing about the new code -- the real test is
# whether the candidate, assembling the same source, reproduces ITSELF.
# So: gen2 = candidate(v1.v0), gen3 = gen2(v1.v0), require gen2 == gen3.
cd "$(dirname "$0")/.."
CAND=${1:-./v1}

$CAND v1.v0 /tmp/fp_gen2 || { echo "gen2 assembly FAILED"; exit 1; }
chmod +x /tmp/fp_gen2
/tmp/fp_gen2 v1.v0 /tmp/fp_gen3 || { echo "gen3 assembly FAILED"; exit 1; }

if cmp -s /tmp/fp_gen2 /tmp/fp_gen3; then
    echo "FIXED POINT OK (gen2 == gen3, $(wc -c < /tmp/fp_gen2) bytes)"
    rc=0
else
    echo "FIXED POINT BROKEN"
    cmp /tmp/fp_gen2 /tmp/fp_gen3
    rc=1
fi
rm -f /tmp/fp_gen2 /tmp/fp_gen3
exit $rc
