# v1difftest_ref.s -- GNU as (Intel syntax) reference for
# tests/v1difftest.v0, one instruction per line in lockstep with it.
#
# The project spec accepts NASM *or* GAS as the differential reference.
# GAS is used because binutils ships on this machine and nasm does not;
# the point of the test is an independent encoder, and as/objdump are as
# independent of ours as nasm is.
#
# Only .text bytes are compared, so no ELF headers or org are needed here
# (see run_difftest.sh, which objcopy's the section out).
	.intel_syntax noprefix
	.text
	movabs rax, 0x123456789ABCDEF0
	movabs r15, 0xFEDCBA9876543210
	mov rax, rbx
	mov r8, r9
	mov rcx, [rax+2000]
	mov [rdx+3000], rsi
	mov rbp, rsp
	mov r10, [r8+4000]
	mov [r9+5000], r14
	movzx rax, byte ptr [rcx+6000]
	mov byte ptr [rdx+7000], r10b
	movzx r15, byte ptr [rbp+500]
	mov byte ptr [r12+600], r8b
	movzx rax, word ptr [rcx+6000]
	mov word ptr [rdx+7000], r10w
	movzx r15, word ptr [rbp+500]
	mov eax, dword ptr [rcx+6000]
	mov dword ptr [rdx+7000], r10d
	mov r15d, dword ptr [r12+600]
	lea rax, [rbx+8000]
	mov rax, [rbx+rcx*8+2000]
	mov [rdx+rsi*4+3000], r9
	mov r10, [r8+r11*2+400]
	movzx rax, byte ptr [rcx+rdx*1+600]
	mov r15d, dword ptr [r12+r13*8+700]
	lea rbx, [rax+rax*4+16000]
	lea r12, [r13+9000]
	imul rax, rcx
	imul r8, r9
	imul rcx, 100000
	imul r11, 250000
	test rcx, 123456
	test r11, 654321
	test rax, rbx
	test r8, r9
	neg rax
	neg r13
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
	call rax
	call r10
	syscall
	ret
	.rept 60
	add rax, rbx
	.endr
target1:
	ret
