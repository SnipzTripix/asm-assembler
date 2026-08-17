#!/usr/bin/env bash
# gen_big.sh -- generate a large .v0 file for throughput benchmarking.
n=${1:-8000}
for ((i=1; i<=n; i++)); do
  echo "mov rax, $i"
  echo "add rax, rbx"
  echo "cmp rax, rcx"
  echo "jl skip$i"
  echo "mov rcx, $i"
  echo "skip$i:"
  echo "add rcx, rdx"
  echo "sub rax, 1"
  echo "mov rdx, rax"
  echo "xor rax, rax"
done
echo "mov rax, 60"
echo "mov rdi, 0"
echo "syscall"
