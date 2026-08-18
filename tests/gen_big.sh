#!/usr/bin/env bash
# gen_big.sh -- generate a large .v0 file for throughput benchmarking.
#
# The register mix matters. This used to emit only rax/rbx/rcx/rdx, which
# happened to be the first four entries of the old linear reg_table, so
# the benchmark could not see a register-parsing change at all: rewriting
# parse_reg made real code 1.9x faster and moved this file by nothing.
# The registers below are spread across all 16, including the r8-r15
# range that costs an extra REX bit and used to cost a full table walk.
n=${1:-8000}
for ((i=1; i<=n; i++)); do
  echo "mov rax, $i"
  echo "add r13, rbx"
  echo "cmp r10, rcx"
  echo "jl skip$i"
  echo "mov rsi, $i"
  echo "skip$i:"
  echo "add r15, rdx"
  echo "sub rdi, 1"
  echo "mov r9, rbp"
  echo "xor r12, r11"
done
echo "mov rax, 60"
echo "mov rdi, 0"
echo "syscall"
