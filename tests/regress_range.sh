#!/usr/bin/env bash
# regress_range.sh -- the four silent-wrong-encoding bugs found by probing.
# Each must now either produce the CORRECT bytes or a clear error, never a
# quietly truncated/biased encoding.
cd "$(dirname "$0")/.."
V=${1:-./v1}

echo "--- equ forward reference: expect imm 05 00 00 00 00 00 00 00 ---"
printf 'mov rax, LATER\nLATER equ 5\nret\n' > /tmp/b1.v0
if $V /tmp/b1.v0 /tmp/b1.bin 2>/tmp/b1.err; then
    tail -c +177 /tmp/b1.bin | od -A d -t x1 | head -1
else
    echo "rc=$? err=$(cat /tmp/b1.err)"
fi

echo "--- disp32 overflow: expect an error ---"
printf 'mov rax, [rbx+99999999999]\nret\n' > /tmp/b2.v0
$V /tmp/b2.v0 /tmp/b2.bin 2>/tmp/b2.err
echo "rc=$? err=$(cat /tmp/b2.err)"

echo "--- imm32 overflow in add: expect an error ---"
printf 'add rax, 0x123456789\nret\n' > /tmp/b3.v0
$V /tmp/b3.v0 /tmp/b3.bin 2>/tmp/b3.err
echo "rc=$? err=$(cat /tmp/b3.err)"

echo "--- imm64 decimal overflow: expect an error ---"
printf 'mov rax, 99999999999999999999999\nret\n' > /tmp/b4.v0
$V /tmp/b4.v0 /tmp/b4.bin 2>/tmp/b4.err
echo "rc=$? err=$(cat /tmp/b4.err)"

echo "--- boundary values that MUST still assemble ---"
printf 'mov rax, 18446744073709551615\nadd rax, 2147483647\nsub rax, -2147483648\nmov rcx, [rbx+2147483647]\nmov rdx, [rbx-2147483648]\nret\n' > /tmp/b5.v0
$V /tmp/b5.v0 /tmp/b5.bin 2>/tmp/b5.err
echo "rc=$? err=$(cat /tmp/b5.err)"

rm -f /tmp/b?.v0 /tmp/b?.bin /tmp/b?.err
