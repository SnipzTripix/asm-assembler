#!/usr/bin/env bash
# repro_cross.sh -- minimal cross-chunk reference test. Builds a file with
# labels and calls deliberately spread so that references cross chunk
# boundaries at various worker counts, then checks parallel == serial.
cd "$(dirname "$0")/.."
V=${1:-./v1}
N=${2:-400}

{
  echo "top:"
  echo "ret"
  for ((i=0; i<N; i++)); do
    echo "mov rax, rbx"
    if [ $((i % 50)) -eq 0 ]; then echo "mid$i:"; fi
    if [ $((i % 37)) -eq 0 ]; then echo "call top"; fi
    if [ $((i % 41)) -eq 0 ]; then echo "mov rcx, top"; fi
  done
  for ((i=0; i<N; i+=50)); do echo "call mid$i"; done
  echo "mov rax, 60"
  echo "mov rdi, 0"
  echo "syscall"
} > /tmp/rc.v0

echo "generated $(wc -l < /tmp/rc.v0) lines"
$V /tmp/rc.v0 /tmp/rc_ser 1 || { echo "serial FAILED"; exit 1; }
for j in 2 3 4 5 8 16; do
    $V /tmp/rc.v0 /tmp/rc_par "$j" 2>/tmp/rc.err
    if [ $? -ne 0 ]; then echo "  -j$j ERROR $(cat /tmp/rc.err)"; continue; fi
    if cmp -s /tmp/rc_ser /tmp/rc_par; then
        echo "  -j$j ok"
    else
        echo "  -j$j DIFFERS: $(cmp -l /tmp/rc_ser /tmp/rc_par | wc -l) bytes"
        cmp -l /tmp/rc_ser /tmp/rc_par | head -4
    fi
done
rm -f /tmp/rc.v0 /tmp/rc_ser /tmp/rc_par /tmp/rc.err
