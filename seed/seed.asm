; ---------------------------------------------------------------------------
; seed.asm -- hand-verified bootstrap assembler (v0.2)
;
; This is the ONE piece of the project built with an external assembler
; (nasm, via `nasm -f bin`). Every field below is fully specified by hand
; with SDM/ELF-spec byte layout in comments; nasm here plays the role of a
; hex editor that resolves `$ - label` arithmetic instead of a calculator --
; it never chooses an encoding for us. nasm %macro use below is likewise
; textual convenience, not a different host language: it still assembles to
; exactly the bytes shown in each macro body, once per invocation.
; Per the project's milestone plan this file is discarded once a generation
; written in its own dialect can assemble itself. Perf/mmap-source/
; no-stack-frame hot-path rules do NOT apply to this file -- it runs a
; handful of times total, during bootstrap only.
;
; Dialect understood (v0.2, line-oriented, one statement per line):
;   mov reg64, imm64            REX.W + B8+rd io      (MOV r64,imm64)
;   mov reg64, reg64            REX.W + 89 /r         (MOV r/m64,r64)
;   mov reg64, [reg64+N]        REX.W + 8B /r         (MOV r64,r/m64) load
;   mov [reg64+N], reg64        REX.W + 89 /r         (MOV r/m64,r64) store
;   mov reg64, label            REX.W + B8+rd io      absolute address (fixup)
;   mov reg64, CONST            same bytes as imm64, CONST substituted now
;   movb reg64, [reg64+N]       REX.W + 0F B6 /r      (MOVZX r64,r/m8) load
;   movb [reg64+N], reg64       REX(always) + 88 /r   (MOV r/m8,r8) store
;   add/sub/and/or/xor/cmp reg64, reg64   REX.W + 01/29/21/09/31/39 /r
;   add/sub/and/or/xor/cmp reg64, imm32   REX.W + 81 /0,/5,/4,/1,/6,/7
;   shl/shr reg64, imm8          REX.W + C1 /4,/5
;   push reg64                  50+rd (+REX.B if >=8)
;   pop  reg64                  58+rd (+REX.B if >=8)
;   jmp/call label               E9/E8 rel32
;   je/jne/jl/jge/jae/jb/ja/jbe/jg/jle label   0F 8x rel32
;   syscall                      0F 05
;   ret                          C3
;   db "literal"                 raw bytes, verbatim copy (no escapes)
;   db imm8                      single raw byte
;   NAME equ imm                 defines NAME as a compile-time constant;
;                                 must appear before any use (no forward
;                                 reference for constants, unlike labels)
;   label:                       defines a symbol at the current offset
;   ; comment                    to end of line; blank lines ignored
;
; N above is a mandatory displacement, decimal or 0x-hex, sign optional
; (e.g. "[rbp+0]", "[rdi+16]", "[rbp-8]") -- there is no bare "[reg]" form,
; keeping the memory-operand grammar free of an optional component.
;
; NOT implemented (documented per project's quality bar, not silently
; wrong): negative/hex immediates anywhere except inside [] operands;
; scaled-index addressing; RIP-relative addressing; 16/32-bit operand
; sizes (register width is always 64 or, for movb, zero-extended-from-8);
; variable-count shifts (imm8 count only); short (rel8) jump encoding --
; every jump/call is emitted at rel32 per the single-pass+backpatch design
; below, so no instruction ever changes size once emitted; forward-
; referenced equ constants (a constant must be defined textually before
; its first use -- labels, unlike constants, may be forward-referenced).
;
; Registers: rax rcx rdx rbx rsp rbp rsi rdi r8-r15 (SDM Vol2 Table 3.1)
;
; I/O: reads entire stdin (fd 0), parses, emits a minimal ELF64 executable
; to stdout (fd 1). No argv, no open/mmap of files -- redirection does the
; file I/O, which keeps this tool to the minimum needed to bootstrap.
;
; Usage:  nasm -f bin seed.asm -o seed && chmod +x seed
;         ./seed < prog.v0 > prog && chmod +x prog && ./prog
; ---------------------------------------------------------------------------
BITS 64
org 0x400000

; === seed's OWN executable header (classic tiny-ELF pattern) ===============
; nasm resolves `$`/`$$`/label arithmetic; every field's meaning is the same
; Elf64_Ehdr / Elf64_Phdr layout used again at runtime below for the OUTPUT
; program -- see that copy for the byte-offset table in comments.
ehdr:
    db      0x7F, "ELF", 2, 1, 1, 0     ; EI_MAG0-3, CLASS=64, DATA=LE, VER=1, OSABI=SYSV
    times 8 db 0                        ; EI_ABIVERSION + 7 bytes padding (9..15)
    dw      2                           ; e_type    = ET_EXEC
    dw      0x3E                        ; e_machine = EM_X86_64
    dd      1                           ; e_version = EV_CURRENT
    dq      _start                      ; e_entry
    dq      phdr - $$                   ; e_phoff
    dq      0                           ; e_shoff   (no section headers)
    dd      0                           ; e_flags
    dw      ehdr_size                   ; e_ehsize
    dw      phdr_size                   ; e_phentsize
    dw      1                           ; e_phnum
    dw      0                           ; e_shentsize
    dw      0                           ; e_shnum
    dw      0                           ; e_shstrndx
ehdr_size equ $ - ehdr                  ; must equal 64

phdr:
    dd      1                           ; p_type  = PT_LOAD
    dd      5                           ; p_flags = PF_R(4)|PF_X(1)
    dq      0                           ; p_offset
    dq      $$                          ; p_vaddr
    dq      $$                          ; p_paddr
    dq      file_size                   ; p_filesz
    dq      file_size                   ; p_memsz
    dq      0x1000                      ; p_align
phdr_size equ $ - phdr                  ; must equal 56

; === syscall numbers (Linux x86-64) =========================================
SYS_read        equ 0
SYS_write       equ 1
SYS_mmap        equ 9
SYS_exit        equ 60

PROT_RW         equ 3                   ; PROT_READ|PROT_WRITE
MAP_PRIV_ANON   equ 0x22                ; MAP_PRIVATE|MAP_ANONYMOUS

; --- memory layout: one mmap, four regions, fixed offsets from rbx ---------
INBUF_OFF       equ 0
OUTBUF_OFF      equ 0x100000
SYMTAB_META_OFF equ 0x200000            ; qword: symbol count
SYMTAB_OFF      equ 0x200008            ; entries, 32B stride
FIXUPS_META_OFF equ 0x300000            ; qword: fixup count
FIXUPS_OFF      equ 0x300008            ; entries, 24B stride
LINE_OFF        equ 0x400000            ; qword: current 1-based source line
MMAP_TOTAL      equ 0x400008

; v1.v0 outgrew the original 64 KiB input buffer long ago. Because the read
; loop simply stopped once the buffer was full, seed assembled the first
; third of the file and then reported an undefined label for everything
; past the cut -- which read as "seed can no longer bootstrap v1" when the
; real fault was a silent truncation. The probe in .read_full makes that
; failure impossible to mistake for anything else.
BUF_LEN         equ 0x100000            ; 1 MiB input capacity
HDR_LEN         equ 120                 ; Elf64_Ehdr(64) + Elf64_Phdr(56)
SYM_ENT         equ 32                  ; {name_ptr:8, name_len:8, value:8, defined:8}
FIX_ENT         equ 24                  ; {patch_off:8, sym_index:8, kind:8}
FIX_REL32       equ 0                   ; jmp/jcc/call operand -- 4-byte PC-relative
FIX_ABS64       equ 1                   ; mov reg,label operand -- 8-byte absolute addr
SYM_CAP         equ 20000
FIX_CAP         equ 20000

; ---------------------------------------------------------------------------
; _start
;   register contract for the whole tool (kept even though this file has no
;   external callers, so every routine below can be read in isolation):
;     rbx = mmap'd region base (all four regions are rbx + *_OFF)
;     r12 = input end pointer  (rbx + bytes actually read)
;     r13 = parse cursor
;     r14 = outbuf base        (rbx + OUTBUF_OFF, constant for the run)
;     r15 = output bump pointer (starts at r14 + HDR_LEN)
; ---------------------------------------------------------------------------
_start:
    xor     edi, edi                    ; addr = NULL
    mov     esi, MMAP_TOTAL
    mov     edx, PROT_RW
    mov     r10d, MAP_PRIV_ANON
    mov     r8, -1                      ; fd = -1 (required for MAP_ANONYMOUS)
    xor     r9d, r9d                    ; offset = 0
    mov     eax, SYS_mmap
    syscall
    cmp     rax, -4095
    jae     die_mmap
    mov     rbx, rax
    lea     r14, [rbx + OUTBUF_OFF]
    ; symtab/fixup counters need no init: MAP_ANONYMOUS pages are zero-filled
    mov     qword [rbx + LINE_OFF], 1    ; line numbers are 1-based

    ; --- read all of stdin into inbuf ---
    xor     r12d, r12d                  ; bytes read so far (offset from rbx)
.read_loop:
    lea     rdi, [rbx + r12]
    mov     rsi, rdi
    mov     rdx, BUF_LEN
    sub     rdx, r12                    ; remaining space
    jz      .read_full                  ; buffer full
    xor     edi, edi                    ; fd = 0
    mov     eax, SYS_read
    syscall
    test    rax, rax
    js      die_read
    jz      .read_done                  ; EOF
    add     r12, rax
    jmp     .read_loop
.read_full:
    ; inbuf is exactly full: one more byte means the source was truncated
    xor     edi, edi
    sub     rsp, 16
    mov     rsi, rsp
    mov     edx, 1
    mov     eax, SYS_read
    syscall
    add     rsp, 16
    test    rax, rax
    jg      die_toobig
.read_done:
    add     r12, rbx                    ; r12 = absolute end pointer
    mov     r13, rbx                    ; cursor = start
    lea     r15, [r14 + HDR_LEN]        ; code emission starts after header

    ; === parse loop: one statement per line =================================
.stmt_loop:
    cmp     r13, r12
    jae     .parse_done
    call    skip_ws
    cmp     r13, r12
    jae     .parse_done
    movzx   eax, byte [r13]
    cmp     al, 10                      ; '\n' -- blank line
    je      .blank
    cmp     al, ';'
    je      .comment
    call    parse_stmt
    jmp     .stmt_loop
.blank:
    inc     r13
    inc     qword [rbx + LINE_OFF]
    jmp     .stmt_loop
.comment:
    call    skip_to_eol
    jmp     .stmt_loop
.parse_done:
    call    resolve_fixups

    ; === build the ELF header for the OUTPUT program into outbuf[0..120) ===
    ; Elf64_Ehdr byte offsets: 0 ident[16] 16 type 18 machine 20 version
    ;   24 entry 32 phoff 40 shoff 48 flags 52 ehsize 54 phentsize 56 phnum
    ;   58 shentsize 60 shnum 62 shstrndx                    (total 64)
    ; Elf64_Phdr byte offsets (abs = 64+rel): 0 type 4 flags 8 offset
    ;   16 vaddr 24 paddr 32 filesz 40 memsz 48 align         (total 56)
    mov     byte [r14+0], 0x7F
    mov     byte [r14+1], 'E'
    mov     byte [r14+2], 'L'
    mov     byte [r14+3], 'F'
    mov     byte [r14+4], 2              ; ELFCLASS64
    mov     byte [r14+5], 1              ; ELFDATA2LSB
    mov     byte [r14+6], 1              ; EV_CURRENT
    mov     byte [r14+7], 0              ; ELFOSABI_SYSV
    mov     qword [r14+8], 0             ; padding 8..15
    mov     word [r14+16], 2             ; e_type = ET_EXEC
    mov     word [r14+18], 0x3E          ; e_machine = EM_X86_64
    mov     dword [r14+20], 1            ; e_version
    mov     qword [r14+24], 0x400000 + HDR_LEN   ; e_entry
    mov     qword [r14+32], 64           ; e_phoff
    mov     qword [r14+40], 0            ; e_shoff
    mov     dword [r14+48], 0            ; e_flags
    mov     word [r14+52], 64            ; e_ehsize
    mov     word [r14+54], 56            ; e_phentsize
    mov     word [r14+56], 1             ; e_phnum
    mov     word [r14+58], 0             ; e_shentsize
    mov     word [r14+60], 0             ; e_shnum
    mov     word [r14+62], 0             ; e_shstrndx

    mov     dword [r14+64], 1            ; p_type = PT_LOAD
    mov     dword [r14+68], 5            ; p_flags = R|X
    mov     qword [r14+72], 0            ; p_offset
    mov     qword [r14+80], 0x400000     ; p_vaddr
    mov     qword [r14+88], 0x400000     ; p_paddr
    mov     rax, r15
    sub     rax, r14                     ; total output length
    mov     qword [r14+96], rax          ; p_filesz
    mov     qword [r14+104], rax         ; p_memsz
    mov     qword [r14+112], 0x1000      ; p_align

    ; --- single write of the whole output image ---
    mov     rdx, rax                     ; length
    mov     rsi, r14                     ; buffer
    mov     edi, 1                       ; fd = 1
    mov     eax, SYS_write
    syscall
    test    rax, rax
    js      die_write

    xor     edi, edi
    mov     eax, SYS_exit
    syscall

; ---------------------------------------------------------------------------
; skip_ws -- advance r13 past spaces/tabs only (not newline)
; ---------------------------------------------------------------------------
skip_ws:
    cmp     r13, r12
    jae     .ret
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .adv
    cmp     al, 9                        ; tab
    jne     .ret
.adv:
    inc     r13
    jmp     skip_ws
.ret:
    ret

; ---------------------------------------------------------------------------
; skip_to_eol -- advance r13 to '\n' (consumed) or end of input
; ---------------------------------------------------------------------------
skip_to_eol:
    cmp     r13, r12
    jae     .ret
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, 10
    jne     skip_to_eol
    inc     qword [rbx + LINE_OFF]
.ret:
    ret

; ---------------------------------------------------------------------------
; scan_ident -- scan an identifier at r13: [A-Za-z0-9_]+ (mnemonics and
; label names both use this; mnemonics happen to never start with a digit,
; so no separate "first char" class check is needed for our own inputs).
;   out: rsi = start, rcx = length; r13 advanced past the identifier
; ---------------------------------------------------------------------------
scan_ident:
    mov     rsi, r13
.loop:
    cmp     r13, r12
    jae     .done
    movzx   eax, byte [r13]
    cmp     al, 'a'
    jb      .maybe_upper
    cmp     al, 'z'
    jbe     .cont
.maybe_upper:
    cmp     al, 'A'
    jb      .maybe_digit
    cmp     al, 'Z'
    jbe     .cont
.maybe_digit:
    cmp     al, '0'
    jb      .maybe_us
    cmp     al, '9'
    jbe     .cont
.maybe_us:
    cmp     al, '_'
    jne     .done
.cont:
    inc     r13
    jmp     .loop
.done:
    mov     rcx, r13
    sub     rcx, rsi
    ret

; ---------------------------------------------------------------------------
; parse_stmt -- dispatch one statement: "ident:" defines a label, "ident equ
; imm" defines a constant, otherwise ident is a mnemonic in mnem_table.
;   in:  r13 = cursor at first non-blank char of the line
;   out: r13 advanced past the line, r15 advanced past any emitted bytes
; ---------------------------------------------------------------------------
parse_stmt:
    call    scan_ident                   ; -> rsi/rcx, r13 advanced
    cmp     rcx, 0
    je      die_unknown_mnem             ; line starts with a non-identifier char
    mov     r10, rsi                     ; stash word1 (name) across everything
    mov     r11, rcx                     ; below -- rsi/rcx get reused as scratch

    cmp     r13, r12
    jae     .checkequ
    cmp     byte [r13], ':'
    jne     .checkequ

    ; --- label definition ---
    inc     r13                          ; consume ':'
    mov     rsi, r10
    mov     rcx, r11
    call    find_or_create_symbol        ; -> eax = index
    call    define_label                 ; eax = index; errs on duplicate
    call    skip_ws
    call    skip_to_eol
    ret

.checkequ:
    ; Peek for a standalone "equ" word without committing r13 past it unless
    ; it's a genuine match: bytes_eq/scan_ident here operate on COPIES of
    ; r13 (rsi), never on r13 itself, so a non-match leaves r13 untouched.
    call    skip_ws
    cmp     r13, r12
    jae     .dispatch
    mov     rsi, r13
    mov     rcx, 3
    lea     rdi, [lit_equ]
    mov     rdx, 3
    call    bytes_eq
    jne     .dispatch
    lea     rax, [r13 + 3]
    cmp     rax, r12
    jae     .isequ
    movzx   eax, byte [rax]              ; boundary char must not continue the word
    cmp     al, 'a'
    jb      .eq_notdigit
    cmp     al, 'z'
    jbe     .dispatch
.eq_notdigit:
    cmp     al, 'A'
    jb      .eq_notupper
    cmp     al, 'Z'
    jbe     .dispatch
.eq_notupper:
    cmp     al, '0'
    jb      .eq_notnum
    cmp     al, '9'
    jbe     .dispatch
.eq_notnum:
    cmp     al, '_'
    je      .dispatch
.isequ:
    add     r13, 3                       ; consume "equ"
    mov     rsi, r10
    mov     rcx, r11
    call    find_or_create_symbol
    mov     r9d, eax
    call    skip_ws
    call    parse_imm
    mov     rdx, rax
    mov     eax, r9d
    call    define_const
    call    skip_ws
    call    skip_to_eol
    ret

.dispatch:
    mov     rsi, r10
    mov     rcx, r11
    lea     r8, [mnem_table]
.mtry:
    mov     rax, [r8]                    ; literal ptr (0 = table terminator)
    test    rax, rax
    jz      die_unknown_mnem
    mov     rdx, [r8 + 8]                ; literal len
    cmp     rcx, rdx
    jne     .mnext
    mov     rdi, rax
    call    bytes_eq                     ; rsi/rcx (candidate) unclobbered by this
    jne     .mnext
    call    [r8 + 16]                    ; handler consumes the rest of the line
    ret
.mnext:
    add     r8, 24
    jmp     .mtry

; ---------------------------------------------------------------------------
; resolve_imm_operand -- parses either a numeric literal or a defined
; equ-constant name at r13. Used anywhere a plain immediate is expected
; (reg,imm arithmetic; shift counts; db byte values) so those contexts can
; take either form.
;   out: eax = value; r13 advanced
; ---------------------------------------------------------------------------
resolve_imm_operand:
    cmp     r13, r12
    jae     die_bad_operand
    movzx   eax, byte [r13]
    cmp     al, '0'
    jb      .const
    cmp     al, '9'
    ja      .const
    call    parse_imm
    ret
.const:
    call    scan_ident
    cmp     rcx, 0
    je      die_bad_operand
    call    try_resolve_const
    jc      die_bad_operand
    ret

; ---------------------------------------------------------------------------
; bytes_eq -- rsi/rcx = candidate ptr/len, rdi/rdx = literal ptr/len
;   out: ZF=1 iff equal (compare via string length first, then rep cmpsb)
;   Preserves rcx/rsi/rdi (saved/restored around cmpsb); only rax is left
;   genuinely clobbered (unused), so callers may treat rsi/rcx as live
;   across this call -- parse_stmt's dispatch loop and find_or_create_symbol
;   both depend on that.
; ---------------------------------------------------------------------------
bytes_eq:
    cmp     rcx, rdx
    jne     .ne
    push    rcx
    push    rsi
    push    rdi
    repe    cmpsb
    pop     rdi
    pop     rsi
    pop     rcx
    ret                                  ; ZF set correctly by cmpsb
.ne:
    cmp     rcx, rdx                     ; force ZF=0 (rcx != rdx already true)
    ret

; ---------------------------------------------------------------------------
; find_or_create_symbol -- rsi/rcx = name ptr/len (points into inbuf, which
; stays mapped for the whole process lifetime, so no string copy is needed)
;   out: eax = symbol index, existing or freshly appended (value=0,defined=0)
;   clob: rax, rcx, rdx, rdi, r8, r9 (rsi preserved: bytes_eq doesn't touch it)
; ---------------------------------------------------------------------------
find_or_create_symbol:
    mov     r8, [rbx + SYMTAB_META_OFF]
    xor     r9, r9
.scan:
    cmp     r9, r8
    jae     .create
    mov     rax, r9
    shl     rax, 5                       ; *32
    lea     rax, [rbx + SYMTAB_OFF + rax]
    mov     rdx, [rax + 8]               ; stored name_len
    cmp     rdx, rcx
    jne     .next
    mov     rdi, [rax]                   ; stored name_ptr
    call    bytes_eq
    jne     .next
    mov     eax, r9d
    ret
.next:
    inc     r9
    jmp     .scan
.create:
    cmp     r8, SYM_CAP
    jae     die_toomany_syms
    mov     rax, r8
    shl     rax, 5
    lea     rax, [rbx + SYMTAB_OFF + rax]
    mov     [rax], rsi                   ; name_ptr
    mov     [rax + 8], rcx               ; name_len
    mov     qword [rax + 16], 0          ; value
    mov     qword [rax + 24], 0          ; defined
    mov     eax, r8d                     ; new index = old count
    inc     r8
    mov     [rbx + SYMTAB_META_OFF], r8
    ret

; ---------------------------------------------------------------------------
; define_label -- eax = symbol index; sets value = current output offset,
; status = 1 (LABEL). Errors if the symbol already has a nonzero status
; (duplicate label, or a name already used as a constant).
; ---------------------------------------------------------------------------
define_label:
    mov     r9d, eax
    mov     rax, r9
    shl     rax, 5
    lea     rax, [rbx + SYMTAB_OFF + rax]
    cmp     qword [rax + 24], 0
    jne     die_dup_label
    mov     rdx, r15
    sub     rdx, r14                     ; offset from outbuf base
    mov     [rax + 16], rdx
    mov     qword [rax + 24], 1
    ret

; ---------------------------------------------------------------------------
; define_const -- eax = symbol index, rdx = value; status = 2 (CONST).
; Errors if the symbol already has a nonzero status.
; ---------------------------------------------------------------------------
define_const:
    mov     r9d, eax
    mov     rax, r9
    shl     rax, 5
    lea     rax, [rbx + SYMTAB_OFF + rax]
    cmp     qword [rax + 24], 0
    jne     die_dup_label
    mov     [rax + 16], rdx
    mov     qword [rax + 24], 2
    ret

; ---------------------------------------------------------------------------
; try_resolve_const -- rsi/rcx = identifier ptr/len. Looks the name up
; WITHOUT creating a new entry (unlike find_or_create_symbol): only a name
; that already exists with status=2 (CONST) counts as found.
;   out: CF=0 and eax=value if found; CF=1 if not (a found value can
;   legitimately equal any 32-bit pattern including 0xFFFFFFFF, so "not
;   found" must be signaled out-of-band via the carry flag rather than by
;   a reserved return value -- a constant named NEG_ONE with that exact
;   low32 pattern is exactly the case an eax==-1 sentinel gets wrong).
; ---------------------------------------------------------------------------
try_resolve_const:
    mov     r8, [rbx + SYMTAB_META_OFF]
    xor     r9, r9
.scan:
    cmp     r9, r8
    jae     .notfound
    mov     r10, r9
    shl     r10, 5
    lea     r10, [rbx + SYMTAB_OFF + r10]
    mov     rdx, [r10 + 8]
    cmp     rdx, rcx
    jne     .next
    mov     rdi, [r10]
    call    bytes_eq
    jne     .next
    cmp     qword [r10 + 24], 2
    jne     .notfound                    ; found, but it's a label not a const
    mov     rax, [r10 + 16]              ; full 64-bit load -- a 32-bit `mov
                                         ; eax` here silently truncated any
                                         ; constant whose value exceeds 32
                                         ; bits (NEG_ONE, MMAP_ERR_THRESH)
                                         ; when later baked into a compiled
                                         ; "mov reg, CONST" via the imm64 form
    clc
    ret
.next:
    inc     r9
    jmp     .scan
.notfound:
    stc
    ret

; ---------------------------------------------------------------------------
; add_fixup -- rdx = patch_off (offset from outbuf base of the field to
; patch), eax = symbol index, ecx = kind (FIX_REL32 / FIX_ABS64)
; ---------------------------------------------------------------------------
add_fixup:
    mov     r8, [rbx + FIXUPS_META_OFF]
    cmp     r8, FIX_CAP
    jae     die_toomany_fixups
    mov     r9, r8
    imul    r9, r9, FIX_ENT              ; not power-of-2 stride; this file
                                         ; is exempt from the no-imul rule
    lea     r9, [rbx + FIXUPS_OFF + r9]
    mov     [r9], rdx
    mov     dword [r9 + 8], eax
    mov     dword [r9 + 16], ecx
    inc     r8
    mov     [rbx + FIXUPS_META_OFF], r8
    ret

; ---------------------------------------------------------------------------
; emit_rel32_ref -- parses a label-name operand at r13. Caller has already
; emitted the opcode byte(s) for a jmp/jcc/call at r15; this writes the
; 4-byte placeholder and records a FIX_REL32 fixup to patch it after the
; full scan (single-pass + backpatch, per the project's forward-reference
; design: the instruction's length is fixed the instant it's emitted, so
; no address ever moves).
; ---------------------------------------------------------------------------
emit_rel32_ref:
    call    scan_ident
    cmp     rcx, 0
    je      die_bad_operand
    call    find_or_create_symbol        ; rsi/rcx -> eax = sym index
    mov     r10d, eax                    ; find_or_create_symbol doesn't touch r10
    mov     dword [r15], 0               ; placeholder rel32
    mov     rdx, r15
    sub     rdx, r14                     ; patch_off
    mov     eax, r10d
    mov     ecx, FIX_REL32
    call    add_fixup
    add     r15, 4
    ret

; ---------------------------------------------------------------------------
; resolve_fixups -- one linear walk; patch every recorded fixup.
;   FIX_REL32: rel32 = target - (patch_off + 4). FIX_ABS64: qword = target +
;   0x400000 (the runtime load address -- unlike rel32, an absolute pointer
;   needs the load bias added back in explicitly; it does NOT cancel out).
; ---------------------------------------------------------------------------
resolve_fixups:
    mov     r8, [rbx + FIXUPS_META_OFF]
    xor     r9, r9
.loop:
    cmp     r9, r8
    jae     .done
    mov     r10, r9
    imul    r10, r10, FIX_ENT
    lea     r10, [rbx + FIXUPS_OFF + r10]
    mov     rax, [r10]                   ; patch_off
    mov     ecx, [r10 + 8]               ; sym index
    mov     r11d, [r10 + 16]             ; kind
    mov     rdx, rcx
    shl     rdx, 5
    lea     rdx, [rbx + SYMTAB_OFF + rdx]
    cmp     qword [rdx + 24], 0
    je      .undef_named
    mov     rsi, [rdx + 16]              ; target value (offset from outbuf base)
    cmp     r11d, FIX_ABS64
    je      .abs64
    sub     rsi, rax
    sub     rsi, 4
    mov     [r14 + rax], esi             ; patch 4 bytes in place
    jmp     .next
.abs64:
    add     rsi, 0x400000                ; load bias -- see comment above
    mov     [r14 + rax], rsi             ; patch 8 bytes in place
.next:
    inc     r9
    jmp     .loop
.undef_named:
    push    rdx                          ; the write below clobbers rdx, which
                                     ; still points at the symbol slot
    ; name the symbol: an undefined label is only discovered here, after
    ; the whole file is scanned, so the name is the only useful handle
    lea     rsi, [msg_undef]
    mov     edx, msg_undef_len
    mov     edi, 2
    mov     eax, SYS_write
    syscall
    lea     rsi, [msg_colonsp]
    mov     edx, 2
    mov     edi, 2
    mov     eax, SYS_write
    syscall
    pop     rax
    mov     rsi, [rax]                   ; name_ptr
    mov     rdx, [rax + 8]               ; name_len
    mov     edi, 2
    mov     eax, SYS_write
    syscall
    lea     rsi, [msg_nl2]
    mov     edx, 1
    mov     edi, 2
    mov     eax, SYS_write
    syscall
    mov     edi, 1
    mov     eax, SYS_exit
    syscall

.done:
    ret

; ---------------------------------------------------------------------------
; emit_rr -- REX.W(+R+B) + opcode + ModRM(mod=11, reg=src, rm=dst)
;   in:  r10b = opcode byte, eax = dst reg (0..15), edx = src reg (0..15)
;   out: r15 advanced by 3
;   clob: rcx, rsi, rdi
; ---------------------------------------------------------------------------
emit_rr:
    mov     cl, 0x48                     ; REX.W, R=X=B=0
    mov     esi, edx
    shr     esi, 3
    shl     esi, 2                       ; REX.R <- src>=8
    or      cl, sil
    mov     esi, eax
    shr     esi, 3                       ; REX.B <- dst>=8
    or      cl, sil
    mov     [r15], cl

    mov     [r15+1], r10b

    mov     esi, edx
    and     esi, 7
    shl     esi, 3
    mov     edi, eax
    and     edi, 7
    or      esi, edi
    or      esi, 0xC0                    ; mod = 11
    mov     [r15+2], sil

    add     r15, 3
    ret

; ---------------------------------------------------------------------------
; emit_mem -- REX.W(+R+B) + opcode + ModRM(mod=10)[+SIB] + disp32
;   in:  r10b = opcode byte, eax = reg field (0..15), edx = base reg (0..15),
;        r9d = signed disp32 (already computed by the caller)
;   out: r15 advanced by 7 (no SIB) or 8 (base is rsp/r12, needs SIB)
;   clob: rcx, rsi, rdi
; ---------------------------------------------------------------------------
emit_mem:
    mov     cl, 0x48
    mov     esi, eax
    shr     esi, 3
    shl     esi, 2                       ; REX.R <- reg field>=8
    or      cl, sil
    mov     esi, edx
    shr     esi, 3                       ; REX.B <- base>=8
    or      cl, sil
    mov     [r15], cl

    mov     [r15+1], r10b

    mov     esi, eax
    and     esi, 7
    shl     esi, 3
    or      esi, 0x80                    ; mod = 10 (disp32)
    mov     edi, edx
    and     edi, 7
    cmp     edi, 4                       ; rsp/r12 low3 == 100 -> SIB required
    je      .need_sib
    or      esi, edi
    mov     [r15+2], sil
    mov     dword [r15+3], r9d
    add     r15, 7
    ret
.need_sib:
    or      esi, 4                       ; rm = 100 -> SIB follows
    mov     [r15+2], sil
    mov     byte [r15+3], 0x24           ; SIB: scale=00 index=100(none) base=100
    mov     dword [r15+4], r9d
    add     r15, 8
    ret

; ---------------------------------------------------------------------------
; emit_movb_load -- REX.W(+R+B) + 0F B6 /r + ModRM[+SIB] + disp32
; (MOVZX r64, r/m8 -- SDM Vol2; zero-extends the loaded byte into the full
; 64-bit dest reg). The r/m8 here is always a memory operand, so this form
; never hits the AH/CH/DH/BH-vs-SPL/BPL/SIL/DIL ambiguity (that only
; affects register-direct byte operands).
;   in:  eax = dst reg (0..15), edx = base reg, r9d = signed disp32
;   out: r15 advanced by 8 (no SIB) or 9 (base is rsp/r12)
;   clob: rcx, rsi, rdi
; ---------------------------------------------------------------------------
emit_movb_load:
    mov     cl, 0x48
    mov     esi, eax
    shr     esi, 3
    shl     esi, 2
    or      cl, sil
    mov     esi, edx
    shr     esi, 3
    or      cl, sil
    mov     [r15], cl
    mov     byte [r15+1], 0x0F
    mov     byte [r15+2], 0xB6

    mov     esi, eax
    and     esi, 7
    shl     esi, 3
    or      esi, 0x80
    mov     edi, edx
    and     edi, 7
    cmp     edi, 4
    je      .sib
    or      esi, edi
    mov     [r15+3], sil
    mov     dword [r15+4], r9d
    add     r15, 8
    ret
.sib:
    or      esi, 4
    mov     [r15+3], sil
    mov     byte [r15+4], 0x24
    mov     dword [r15+5], r9d
    add     r15, 9
    ret

; ---------------------------------------------------------------------------
; emit_movb_store -- REX(always present) + 88 /r + ModRM[+SIB] + disp32
; (MOV r/m8, r8 -- SDM Vol2). The source register's BYTE is stored; the
; reg field IS register-direct in spirit (it names which register's low
; byte), so without a REX prefix, reg=4..7 would mean AH/CH/DH/BH instead
; of our intended SPL/BPL/SIL/DIL -- REX is therefore forced unconditionally
; (0x40 minimum) rather than only when W/R/B bits are otherwise needed.
;   in:  eax = src reg (0..15), edx = base reg, r9d = signed disp32
;   out: r15 advanced by 7 (no SIB) or 8 (base is rsp/r12)
;   clob: rcx, rsi, rdi
; ---------------------------------------------------------------------------
emit_movb_store:
    mov     cl, 0x40                     ; REX present unconditionally
    mov     esi, eax
    shr     esi, 3
    shl     esi, 2
    or      cl, sil
    mov     esi, edx
    shr     esi, 3
    or      cl, sil
    mov     [r15], cl
    mov     byte [r15+1], 0x88

    mov     esi, eax
    and     esi, 7
    shl     esi, 3
    or      esi, 0x80
    mov     edi, edx
    and     edi, 7
    cmp     edi, 4
    je      .sib
    or      esi, edi
    mov     [r15+2], sil
    mov     dword [r15+3], r9d
    add     r15, 7
    ret
.sib:
    or      esi, 4
    mov     [r15+2], sil
    mov     byte [r15+3], 0x24
    mov     dword [r15+4], r9d
    add     r15, 8
    ret

; ---------------------------------------------------------------------------
; emit_grp1_imm -- REX.W(+B) + 81 /digit + ModRM + imm32
; (immediate-group-1 ops: ADD=/0 OR=/1 AND=/4 SUB=/5 XOR=/6 CMP=/7, all
; "r/m64, imm32" with the imm32 sign-extended -- SDM Vol2 Table A-6). The
; /digit is an opcode extension, not a register, so REX.R is never set here.
;   in:  r10d = /digit (0,1,4,5,6,7), eax = dst reg, r9d = imm32
;   out: r15 advanced by 7
;   clob: rcx, rsi, rdi
; ---------------------------------------------------------------------------
emit_grp1_imm:
    mov     cl, 0x48
    mov     esi, eax
    shr     esi, 3                       ; REX.B <- dst>=8
    or      cl, sil
    mov     [r15], cl
    mov     byte [r15+1], 0x81

    mov     esi, eax
    and     esi, 7
    mov     edi, r10d
    shl     edi, 3
    or      esi, edi
    or      esi, 0xC0                    ; mod = 11
    mov     [r15+2], sil
    mov     dword [r15+3], r9d
    add     r15, 7
    ret

; ---------------------------------------------------------------------------
; emit_shift_imm -- REX.W(+B) + C1 /digit + ModRM + imm8
; (SHL r/m64,imm8 = /4, SHR r/m64,imm8 = /5 -- SDM Vol2)
;   in:  r10d = /digit (4 or 5), eax = dst reg, r11b = imm8 count
;   out: r15 advanced by 4
;   clob: rcx, rsi, rdi
; ---------------------------------------------------------------------------
emit_shift_imm:
    mov     cl, 0x48
    mov     esi, eax
    shr     esi, 3
    or      cl, sil
    mov     [r15], cl
    mov     byte [r15+1], 0xC1

    mov     esi, eax
    and     esi, 7
    mov     edi, r10d
    shl     edi, 3
    or      esi, edi
    or      esi, 0xC0
    mov     [r15+2], sil
    mov     [r15+3], r11b
    add     r15, 4
    ret

; ---------------------------------------------------------------------------
; parse_mem -- parses "[reg64+imm]" or "[reg64-imm]" at r13 (must start
; with '[').
;   out: eax = base register 0..15, r9d = signed disp32; r13 advanced past ']'
;   clob: rax, rcx, rdx, rsi, rdi, r9, r10, r11 (via parse_reg/parse_imm)
; ---------------------------------------------------------------------------
parse_mem:
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], '['
    jne     die_bad_operand
    inc     r13
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    push    rax                          ; base reg -- parse_imm returns in
                                         ; rax too, so it can't stay there
    cmp     r13, r12
    jae     die_bad_operand
    movzx   ecx, byte [r13]
    cmp     cl, '+'
    je      .pos
    cmp     cl, '-'
    je      .neg
    jmp     die_bad_operand
.pos:
    inc     r13
    call    parse_imm
    jmp     .haveimm
.neg:
    inc     r13
    call    parse_imm
    neg     rax
.haveimm:
    mov     r9d, eax
    pop     rax
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ']'
    jne     die_bad_operand
    inc     r13
    ret

; ---------------------------------------------------------------------------
; do_mov -- all four forms: reg,imm64 / reg,reg / reg,[mem] / [mem],reg
;   REX = 0100_W_R_X_B = 0x48 base, with B=1 if reg>=8 for the imm form
;   (opcode-embedded reg uses REX.B to extend, per SDM Vol2 3.1.1.1 -- no
;   ModRM in that form); the other three go through emit_rr/emit_mem.
; ---------------------------------------------------------------------------
do_mov:
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], '['
    je      .store

    call    parse_reg                    ; first operand
    cmp     eax, -1
    je      die_bad_operand
    push    rax                          ; dst reg -- parse_reg/parse_imm/
                                         ; parse_mem all clobber r10/r11, so
                                         ; this can't live in a register
                                         ; across them; the stack can hold it

    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], '['
    je      .load

    movzx   eax, byte [r13]
    cmp     al, '0'
    jb      .try_reg_or_label
    cmp     al, '9'
    jbe     .imm_numeric

.try_reg_or_label:
    call    parse_reg                    ; r13 is left unchanged on failure,
    cmp     eax, -1                      ; so a miss here can fall through
    jne     .regreg_have_src             ; to scan_ident cleanly below
    call    scan_ident                   ; --- mov reg, label-or-const ---
    cmp     rcx, 0
    je      die_bad_operand
    call    try_resolve_const            ; rsi/rcx still live (bytes_eq-clean)
    jnc     .const_have_value            ; it's a known constant -- use it now

    ; not a constant: treat as a (possibly forward-referenced) label address
    call    find_or_create_symbol        ; rsi/rcx -> eax = sym index
    mov     r11d, eax
    pop     rax                          ; dst reg
    mov     r10d, eax
    mov     al, 0x48
    mov     ecx, r10d
    shr     ecx, 3
    or      al, cl
    mov     byte [r15], al
    mov     ecx, r10d
    and     ecx, 7
    add     cl, 0xB8                     ; opcode B8+rd
    mov     byte [r15+1], cl
    mov     qword [r15+2], 0             ; placeholder imm64, patched as FIX_ABS64
    mov     rdx, r15
    add     rdx, 2
    sub     rdx, r14                     ; patch_off of the imm64 field
    mov     eax, r11d
    mov     ecx, FIX_ABS64
    call    add_fixup
    add     r15, 10
    jmp     .tail

.const_have_value:
    mov     r10, rax                     ; constant's value
    pop     rax                          ; dst reg
    mov     r11d, eax
    mov     al, 0x48
    mov     ecx, r11d
    shr     ecx, 3
    or      al, cl
    mov     byte [r15], al
    mov     ecx, r11d
    and     ecx, 7
    add     cl, 0xB8
    mov     byte [r15+1], cl
    mov     qword [r15+2], r10
    add     r15, 10
    jmp     .tail

.imm_numeric:
    call    parse_imm
    mov     r10, rax
    pop     rax
    mov     r11d, eax
    mov     al, 0x48
    mov     ecx, r11d
    shr     ecx, 3
    or      al, cl
    mov     byte [r15], al
    mov     ecx, r11d
    and     ecx, 7
    add     cl, 0xB8                     ; opcode B8+rd
    mov     byte [r15+1], cl
    mov     qword [r15+2], r10
    add     r15, 10
    jmp     .tail

.regreg_have_src:
    mov     edx, eax                     ; src (already parsed above)
    pop     rax                          ; dst
    mov     r10b, 0x89                   ; MOV r/m64, r64
    call    emit_rr
    jmp     .tail

.load:
    call    parse_mem                    ; -> eax=base, r9d=disp
    mov     edx, eax                     ; base
    pop     rax                          ; dst -> reg field
    mov     r10b, 0x8B                   ; MOV r64, r/m64
    call    emit_mem
    jmp     .tail

.store:
    call    parse_mem                    ; -> eax=base, r9d=disp
    mov     edx, eax                     ; base
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    push    rdx                          ; preserve base/disp across parse_reg
    push    r9
    call    parse_reg                    ; src reg
    cmp     eax, -1
    je      die_bad_operand
    pop     r9
    pop     rdx
    mov     r10b, 0x89                   ; MOV r/m64, r64
    call    emit_mem                     ; eax=src(reg field), edx=base, r9d=disp

.tail:
    call    skip_ws
    call    skip_to_eol
    ret

; ---------------------------------------------------------------------------
; add/sub/and/or/xor/cmp reg64, reg64-or-imm -- two shapes dispatched on
; whether the second operand starts with a digit (numeric), else it's
; resolved as a register or an equ-constant (via resolve_imm_operand's
; sibling logic, inlined here since the register-vs-constant check needs
; parse_reg tried first, same pattern as do_mov's operand dispatch).
; ---------------------------------------------------------------------------
%macro DEF_ARITH_RI 3                    ; name, grp1 /digit, rr opcode
do_%1:
    call    skip_ws
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    push    rax
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    movzx   eax, byte [r13]
    cmp     al, '0'
    jb      .%1_reg_or_const
    cmp     al, '9'
    ja      .%1_reg_or_const

    call    parse_imm                    ; --- imm form ---
    mov     r9d, eax
    pop     rax
    mov     r10d, %2
    call    emit_grp1_imm
    jmp     .%1_tail

.%1_reg_or_const:
    call    parse_reg
    cmp     eax, -1
    jne     .%1_have_src
    call    scan_ident                   ; not a register -- try a constant
    cmp     rcx, 0
    je      die_bad_operand
    call    try_resolve_const
    jc      die_bad_operand
    mov     r9d, eax
    pop     rax
    mov     r10d, %2
    call    emit_grp1_imm
    jmp     .%1_tail
.%1_have_src:
    mov     edx, eax                     ; src
    pop     rax                          ; dst
    mov     r10b, %3
    call    emit_rr
.%1_tail:
    call    skip_ws
    call    skip_to_eol
    ret
%endmacro

DEF_ARITH_RI add, 0, 0x01
DEF_ARITH_RI or,  1, 0x09
DEF_ARITH_RI and, 4, 0x21
DEF_ARITH_RI sub, 5, 0x29
DEF_ARITH_RI xor, 6, 0x31
DEF_ARITH_RI cmp, 7, 0x39

; ---------------------------------------------------------------------------
; do_imul -- IMUL r64, r/m64 (REX.W + 0F AF /r).
; Added so this bootstrap tool can still assemble the current v1.v0: unlike
; the group-1 ops its ModRM is reg=dst, rm=src (RM, not MR), so it cannot
; reuse emit_rr.
; ---------------------------------------------------------------------------
do_imul:
    call    skip_ws
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    push    rax
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    mov     edx, eax                     ; src
    pop     rax                          ; dst
    mov     cl, 0x48                     ; REX.W
    mov     esi, eax
    shr     esi, 3
    shl     esi, 2                       ; REX.R from dst (it is the reg field)
    or      cl, sil
    mov     esi, edx
    shr     esi, 3                       ; REX.B from src (the rm field)
    or      cl, sil
    mov     [r15], cl
    mov     byte [r15 + 1], 0x0F
    mov     byte [r15 + 2], 0xAF
    mov     esi, eax
    and     esi, 7
    shl     esi, 3
    mov     edi, edx
    and     edi, 7
    or      esi, edi
    or      esi, 0xC0                    ; mod = 11
    mov     [r15 + 3], sil
    add     r15, 4
    call    skip_ws
    call    skip_to_eol
    ret

; ---------------------------------------------------------------------------
; shl/shr reg64, imm8 -- variable-count (shift by cl) form not implemented
; ---------------------------------------------------------------------------
%macro DEF_SHIFT_I 2                     ; name, /digit
do_%1:
    call    skip_ws
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    push    rax
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    call    resolve_imm_operand
    mov     r11b, al
    pop     rax
    mov     r10d, %2
    call    emit_shift_imm
    call    skip_ws
    call    skip_to_eol
    ret
%endmacro

DEF_SHIFT_I shl, 4
DEF_SHIFT_I shr, 5

; ---------------------------------------------------------------------------
; movb reg64, [reg64+N]  /  movb [reg64+N], reg64 -- byte load (zero-
; extended) and byte store, the only sub-64-bit memory access in the
; dialect. Needed for character-at-a-time scanning/comparison.
; ---------------------------------------------------------------------------
do_movb:
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], '['
    je      .store

    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    push    rax
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    call    parse_mem                    ; -> eax=base, r9d=disp
    mov     edx, eax
    pop     rax                          ; dst -> reg field
    call    emit_movb_load
    jmp     .tail

.store:
    call    parse_mem                    ; -> eax=base, r9d=disp
    mov     edx, eax
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], ','
    jne     die_bad_operand
    inc     r13
    call    skip_ws
    push    rdx
    push    r9
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    pop     r9
    pop     rdx
    call    emit_movb_store              ; eax=src(reg field), edx=base, r9d=disp
.tail:
    call    skip_ws
    call    skip_to_eol
    ret

; ---------------------------------------------------------------------------
; push/pop reg64 -- 50+rd/58+rd, REX.B prefix only when reg>=8 (no REX.W:
; PUSH/POP default to 64-bit operand size in long mode, SDM Vol2)
; ---------------------------------------------------------------------------
%macro DEF_PUSHPOP 2                     ; name, base opcode
do_%1:
    call    skip_ws
    call    parse_reg
    cmp     eax, -1
    je      die_bad_operand
    mov     ecx, eax
    cmp     ecx, 8
    jl      .no_rex
    mov     byte [r15], 0x41             ; REX.B
    mov     edx, ecx
    and     edx, 7
    add     dl, %2
    mov     byte [r15+1], dl
    add     r15, 2
    jmp     .done
.no_rex:
    add     cl, %2
    mov     byte [r15], cl
    inc     r15
.done:
    call    skip_ws
    call    skip_to_eol
    ret
%endmacro

DEF_PUSHPOP push, 0x50
DEF_PUSHPOP pop, 0x58

; ---------------------------------------------------------------------------
; jmp/call/je/jne/jl/jge label -- opcode(s) then a rel32 label reference
; ---------------------------------------------------------------------------
%macro DEF_JCC 3                         ; name, opcode1, opcode2 (0 = none)
do_%1:
    call    skip_ws
%if %3 = 0
    mov     byte [r15], %2
    inc     r15
%else
    mov     byte [r15], %2
    mov     byte [r15+1], %3
    add     r15, 2
%endif
    call    emit_rel32_ref
    call    skip_ws
    call    skip_to_eol
    ret
%endmacro

DEF_JCC jmp,  0xE9, 0                    ; JMP rel32
DEF_JCC call, 0xE8, 0                    ; CALL rel32
DEF_JCC je,   0x0F, 0x84                 ; JE  rel32 (ZF=1)
DEF_JCC jne,  0x0F, 0x85                 ; JNE rel32 (ZF=0)
DEF_JCC jl,   0x0F, 0x8C                 ; JL  rel32 (SF!=OF)   signed <
DEF_JCC jge,  0x0F, 0x8D                 ; JGE rel32 (SF=OF)    signed >=
DEF_JCC jg,   0x0F, 0x8F                 ; JG  rel32 (ZF=0,SF=OF) signed >
DEF_JCC jle,  0x0F, 0x8E                 ; JLE rel32 (ZF=1 or SF!=OF) signed <=
DEF_JCC jb,   0x0F, 0x82                 ; JB  rel32 (CF=1)     unsigned <
DEF_JCC jae,  0x0F, 0x83                 ; JAE rel32 (CF=0)     unsigned >=
DEF_JCC ja,   0x0F, 0x87                 ; JA  rel32 (CF=0,ZF=0) unsigned >
DEF_JCC jbe,  0x0F, 0x86                 ; JBE rel32 (CF=1 or ZF=1) unsigned <=

; ---------------------------------------------------------------------------
; do_syscall -- SYSCALL, opcode 0F 05 (SDM Vol2)
; ---------------------------------------------------------------------------
do_syscall:
    mov     byte [r15], 0x0F
    mov     byte [r15+1], 0x05
    add     r15, 2
    call    skip_ws
    call    skip_to_eol
    ret

; ---------------------------------------------------------------------------
; do_ret -- RET (near), opcode C3 (SDM Vol2)
; ---------------------------------------------------------------------------
do_ret:
    mov     byte [r15], 0xC3
    inc     r15
    call    skip_ws
    call    skip_to_eol
    ret

; ---------------------------------------------------------------------------
; do_db -- db "literal bytes" (verbatim copy, no escapes) or db imm8/CONST
; (a single raw byte)
; ---------------------------------------------------------------------------
do_db:
    call    skip_ws
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], '"'
    je      .stringform

    call    resolve_imm_operand
    mov     [r15], al
    inc     r15
    jmp     .tail

.stringform:
    inc     r13
.copy:
    cmp     r13, r12
    jae     die_bad_operand             ; unterminated string
    movzx   eax, byte [r13]
    cmp     al, '"'
    je      .close
    mov     [r15], al
    inc     r15
    inc     r13
    jmp     .copy
.close:
    inc     r13                          ; consume closing quote
.tail:
    call    skip_ws
    call    skip_to_eol
    ret

; ---------------------------------------------------------------------------
; parse_reg -- match a register name at r13 against reg_table
;   out: eax = register number 0..15, or -1 if no match; r13 advanced past
;        the name on success (left unchanged on failure)
;   clob: rcx, rdx, rsi, rdi, r10, r11
; ---------------------------------------------------------------------------
parse_reg:
    lea     r10, [reg_table]
    mov     r11d, 16                     ; 16 entries to try
.try:
    movzx   ecx, byte [r10]              ; name length
    lea     rsi, [r13]
    lea     rdi, [r10 + 3]               ; name bytes start at offset 3
    mov     rdx, rcx
    push    r11
    push    r10
    call    bytes_eq
    pop     r10
    pop     r11
    jne     .next
    ; boundary check: char after the match must not be ident-continuation
    movzx   eax, byte [r10]              ; reload name length (rcx was clobbered by bytes_eq)
    mov     edx, eax
    lea     rax, [r13 + rdx]
    cmp     rax, r12
    jae     .accept
    movzx   eax, byte [rax]
    cmp     al, 'a'
    jb      .boundary_ok
    cmp     al, 'z'
    jbe     .next
.boundary_ok:
    cmp     al, '0'
    jb      .accept
    cmp     al, '9'
    jbe     .next
.accept:
    movzx   eax, byte [r10]
    add     r13, rax                     ; advance cursor past register name
    movzx   eax, byte [r10 + 1]          ; register number stored at offset 1
    ret
.next:
    add     r10, REG_ENT_LEN
    dec     r11d
    jnz     .try
    mov     eax, -1
    ret

; ---------------------------------------------------------------------------
; parse_imm -- decimal or 0x-hex unsigned 64-bit immediate at r13
;   out: rax = value; r13 advanced past the digits
;   clob: rcx, rdx, r8
; ---------------------------------------------------------------------------
parse_imm:
    xor     eax, eax
    cmp     r13, r12
    jae     die_bad_operand
    cmp     byte [r13], '0'
    jne     .decimal
    cmp     r13, r12
    jae     .decimal
    lea     rdx, [r13 + 1]
    cmp     rdx, r12
    jae     .decimal
    movzx   ecx, byte [r13 + 1]
    cmp     cl, 'x'
    jne     .decimal
    add     r13, 2
.hex_loop:
    cmp     r13, r12
    jae     .done
    movzx   ecx, byte [r13]
    cmp     cl, '0'
    jb      .done
    cmp     cl, '9'
    jbe     .hex_digit
    or      cl, 0x20                     ; lowercase a-f
    cmp     cl, 'a'
    jb      .done
    cmp     cl, 'f'
    ja      .done
    sub     cl, 'a' - 10
    jmp     .hex_acc
.hex_digit:
    sub     cl, '0'
.hex_acc:
    shl     rax, 4
    movzx   r8, cl
    or      rax, r8
    inc     r13
    jmp     .hex_loop
.decimal:
    xor     eax, eax
.dec_loop:
    cmp     r13, r12
    jae     .done
    movzx   ecx, byte [r13]
    cmp     cl, '0'
    jb      .done
    cmp     cl, '9'
    ja      .done
    sub     cl, '0'
    lea     rax, [rax + rax*4]           ; rax = rax*5 ...
    shl     rax, 1                       ; ... *2 = *10
    movzx   r8, cl
    add     rax, r8
    inc     r13
    jmp     .dec_loop
.done:
    ret

; ---------------------------------------------------------------------------
; die_* -- error exits. fd 2, distinct message each, status 1.
; ---------------------------------------------------------------------------
die_toobig:
    lea     rsi, [msg_toobig]
    mov     edx, msg_toobig_len
    jmp     die
die_mmap:
    lea     rsi, [msg_mmap]
    mov     edx, msg_mmap_len
    jmp     die
die_read:
    lea     rsi, [msg_read]
    mov     edx, msg_read_len
    jmp     die
die_write:
    lea     rsi, [msg_write]
    mov     edx, msg_write_len
    jmp     die
die_unknown_mnem:
    lea     rsi, [msg_unknown]
    mov     edx, msg_unknown_len
    jmp     die_at_line
die_bad_operand:
    lea     rsi, [msg_operand]
    mov     edx, msg_operand_len
    jmp     die_at_line
die_dup_label:
    lea     rsi, [msg_dup]
    mov     edx, msg_dup_len
    jmp     die_at_line
die_undef_label:
    lea     rsi, [msg_undef]
    mov     edx, msg_undef_len
    jmp     die_at_line
die_toomany_syms:
    lea     rsi, [msg_toomanysyms]
    mov     edx, msg_toomanysyms_len
    jmp     die_at_line
die_toomany_fixups:
    lea     rsi, [msg_toomanyfix]
    mov     edx, msg_toomanyfix_len
    jmp     die_at_line

; die -- rsi/rdx = message (already includes its own trailing newline).
; For I/O-level failures (mmap/read/write) where a source line number
; wouldn't mean anything.
die:
    mov     edi, 2
    mov     eax, SYS_write
    syscall
    mov     edi, 1
    mov     eax, SYS_exit
    syscall

; die_at_line -- rsi/rdx = message (NO trailing newline). Appends
; " at line N\n" using the running line counter, then exits 1. For every
; parse-time error, where the line number is the single most useful piece
; of context to hand back.
die_at_line:
    mov     edi, 2
    mov     eax, SYS_write
    syscall

    lea     rsi, [msg_atline]
    mov     edx, msg_atline_len
    mov     edi, 2
    mov     eax, SYS_write
    syscall

    mov     rax, [rbx + LINE_OFF]
    call    print_udec

    lea     rsi, [msg_nl]
    mov     edx, 1
    mov     edi, 2
    mov     eax, SYS_write
    syscall

    mov     edi, 1
    mov     eax, SYS_exit
    syscall

; ---------------------------------------------------------------------------
; print_udec -- rax = unsigned value; writes its decimal digits to fd 2.
; Digits are produced least-significant-first via DIV, buffered in the red
; zone, then written most-significant-first. This is a cold, once-per-
; process-exit path (error reporting only), so DIV and a byte-at-a-time
; write loop are fine -- neither the no-div nor the one-write-per-run rule
; is meant to constrain error paths that immediately terminate the process.
;   clob: rax, rcx, rdx, rsi, rdi, r8, r9
; ---------------------------------------------------------------------------
print_udec:
    lea     r8, [rsp - 64]               ; red-zone scratch (well under 128B)
    xor     r9, r9                       ; digit count
    mov     rcx, 10
.divloop:
    xor     rdx, rdx
    div     rcx
    add     dl, '0'
    mov     [r8 + r9], dl
    inc     r9
    test    rax, rax
    jnz     .divloop
.wloop:
    dec     r9
    lea     rsi, [r8 + r9]
    mov     edx, 1
    mov     edi, 2
    mov     eax, SYS_write
    syscall
    test    r9, r9
    jnz     .wloop
    ret

; === read-only data ==========================================================
msg_mmap:          db "seed: mmap failed", 10
msg_mmap_len       equ $ - msg_mmap
msg_toobig:        db "seed: input larger than buffer", 10
msg_toobig_len     equ $ - msg_toobig
msg_read:          db "seed: read failed", 10
msg_read_len       equ $ - msg_read
msg_write:         db "seed: write failed", 10
msg_write_len      equ $ - msg_write
msg_unknown:       db "seed: unknown mnemonic"
msg_unknown_len    equ $ - msg_unknown
msg_operand:       db "seed: bad operand"
msg_operand_len    equ $ - msg_operand
msg_dup:           db "seed: duplicate label"
msg_dup_len        equ $ - msg_dup
msg_colonsp:       db ": "
msg_nl2:           db 10
msg_undef:         db "seed: undefined label"
msg_undef_len      equ $ - msg_undef
msg_toomanysyms:   db "seed: too many symbols"
msg_toomanysyms_len equ $ - msg_toomanysyms
msg_toomanyfix:    db "seed: too many fixups"
msg_toomanyfix_len equ $ - msg_toomanyfix
msg_atline:        db " at line "
msg_atline_len     equ $ - msg_atline
msg_nl:            db 10

; reg_table entry = { u8 name_len, u8 reg_num, u8 pad, char name[8 max] }
; fixed 11-byte stride so parse_reg indexes it without imul.
REG_ENT_LEN     equ 11
reg_table:
    db 3, 0, 0, "rax", 0,0,0,0,0
    db 3, 1, 0, "rcx", 0,0,0,0,0
    db 3, 2, 0, "rdx", 0,0,0,0,0
    db 3, 3, 0, "rbx", 0,0,0,0,0
    db 3, 4, 0, "rsp", 0,0,0,0,0
    db 3, 5, 0, "rbp", 0,0,0,0,0
    db 3, 6, 0, "rsi", 0,0,0,0,0
    db 3, 7, 0, "rdi", 0,0,0,0,0
    db 2, 8, 0, "r8",  0,0,0,0,0,0
    db 2, 9, 0, "r9",  0,0,0,0,0,0
    db 3, 10, 0, "r10", 0,0,0,0,0
    db 3, 11, 0, "r11", 0,0,0,0,0
    db 3, 12, 0, "r12", 0,0,0,0,0
    db 3, 13, 0, "r13", 0,0,0,0,0
    db 3, 14, 0, "r14", 0,0,0,0,0
    db 3, 15, 0, "r15", 0,0,0,0,0

; mnem_table entry = { literal ptr:8, literal len:8, handler ptr:8 }
; linear scan -- bucketing by first letter is a perf technique this file
; is explicitly exempt from; see file header. ("equ" is handled specially
; in parse_stmt, not through this table.)
lit_equ:     db "equ"
lit_mov:     db "mov"
lit_movb:    db "movb"
lit_syscall: db "syscall"
lit_ret:     db "ret"
lit_db:      db "db"
lit_add:     db "add"
lit_or:      db "or"
lit_and:     db "and"
lit_sub:     db "sub"
lit_xor:     db "xor"
lit_cmp:     db "cmp"
lit_shl:     db "shl"
lit_shr:     db "shr"
lit_jmp:     db "jmp"
lit_je:      db "je"
lit_jne:     db "jne"
lit_jl:      db "jl"
lit_jge:     db "jge"
lit_jg:      db "jg"
lit_jle:     db "jle"
lit_jb:      db "jb"
lit_jae:     db "jae"
lit_ja:      db "ja"
lit_jbe:     db "jbe"
lit_call:    db "call"
lit_push:    db "push"
lit_pop:     db "pop"
lit_imul:    db "imul"

align 8
mnem_table:
    dq lit_mov,     3, do_mov
    dq lit_movb,    4, do_movb
    dq lit_syscall, 7, do_syscall
    dq lit_ret,     3, do_ret
    dq lit_db,      2, do_db
    dq lit_add,     3, do_add
    dq lit_or,      2, do_or
    dq lit_and,     3, do_and
    dq lit_sub,     3, do_sub
    dq lit_xor,     3, do_xor
    dq lit_cmp,     3, do_cmp
    dq lit_shl,     3, do_shl
    dq lit_shr,     3, do_shr
    dq lit_jmp,     3, do_jmp
    dq lit_je,      2, do_je
    dq lit_jne,     3, do_jne
    dq lit_jl,      2, do_jl
    dq lit_jge,     3, do_jge
    dq lit_jg,      2, do_jg
    dq lit_jle,     3, do_jle
    dq lit_jb,      2, do_jb
    dq lit_jae,     3, do_jae
    dq lit_ja,      2, do_ja
    dq lit_jbe,     3, do_jbe
    dq lit_call,    4, do_call
    dq lit_push,    4, do_push
    dq lit_pop,     3, do_pop
    dq lit_imul,    4, do_imul
    dq 0, 0, 0

file_size equ $ - $$
