#!/usr/bin/env bash
# probe.sh -- edge-case battery, hunting for crashes/wrong behavior.
cd "$(dirname "$0")/.."
p() {
    printf '%b' "$2" > /tmp/probe.v0
    ./v1 /tmp/probe.v0 /tmp/probe.bin 2>/tmp/probe.err
    echo "[$1] rc=$? err=$(head -c 80 /tmp/probe.err | tr '\n' ' ')"
}

p "empty file"            ''
p "only comment"          '; nothing here\n'
p "only newlines"         '\n\n\n'
p "no trailing newline"   'ret'
p "label no newline"      'foo:'
p "dup label"             'a:\nret\na:\nret\n'
p "undef label"           'jmp nowhere\n'
p "bad reg"               'mov rzz, 1\n'
p "missing comma"         'mov rax 1\n'
p "missing operand"       'mov rax,\n'
p "trailing comma"        'mov rax, 1,\n'
p "unterminated string"   'db "abc\n'
p "empty string"          'db ""\n'
p "huge imm"              'mov rax, 99999999999999999999999\n'
p "neg shift"             'shl rax, -1\n'
p "equ fwd ref"           'mov rax, LATER\nLATER equ 5\n'
p "equ then label same"   'X equ 5\nX:\nret\n'
p "label then equ same"   'X:\nret\nX equ 5\n'
p "mem no disp"           'mov rax, [rbx]\n'
p "mem huge disp"         'mov rax, [rbx+99999999999]\n'
p "tab indent"            '\tret\n'
p "crlf line endings"     'ret\r\nret\r\n'
p "case sensitivity"      'MOV rax, 1\n'
p "reg as label"          'rax:\nret\n'
p "deep whitespace"       'mov     rax  ,   1\n'
rm -f /tmp/probe.v0 /tmp/probe.bin /tmp/probe.err
