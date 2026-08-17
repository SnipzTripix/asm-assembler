; v1difftest_ref.asm -- nasm reference for tests/v1difftest.v0. org matches
; where our code actually starts at runtime (0x400000 + v1's 176-byte
; header: Ehdr(64) + 2*Phdr(56), one PT_LOAD each for .text and .data).
; Assemble with: nasm -f bin
BITS 64
org 0x4000B0

mov rax, 0x123456789ABCDEF0
mov r15, 0xFEDCBA9876543210
mov rax, rbx
mov r8, r9
mov rcx, [rax+2000]
mov [rdx+3000], rsi
mov rbp, rsp
mov r10, [r8+4000]
mov [r9+5000], r14
movzx rax, byte [rcx+6000]
mov [rdx+7000], r10b
movzx r15, byte [rbp+500]
mov [r12+600], r8b
lea rax, [rbx+8000]
lea r12, [r13+9000]
imul rax, rcx
imul r8, r9
add rax, rbx
add r12, r13
add rcx, 1000
add r14, 2000
sub rax, rbx
sub rcx, 500
and rax, rbx
and rcx, 0x1234
or rax, rbx
or rcx, 0x2345
xor rax, rbx
xor rcx, 0x3456
cmp rax, rbx
cmp rcx, 4200
cmp r8, r9
cmp rsi, -100000
add rsi, -100000
sub rsi, -100000
shl rax, 4
shr r9, 2
shl r15, 3
push rax
push r15
push r8
pop rbx
pop r8
pop r15
jmp target1
je target1
jne target1
jl target1
jae target1
call target1
syscall
ret
times 50 add rax, rbx
target1:
ret
