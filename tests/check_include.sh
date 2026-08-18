#!/usr/bin/env bash
# check_include.sh -- %include splicing: shorter than the directive line,
# longer than it, nested, and at end of file.
cd "$(dirname "$0")/.."
V=${1:-./v1}
fail=0
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

expect_exit() { # expect_exit <name> <wanted> <src>
    local name="$1" want="$2" src="$3"
    $V "$src" "$D/out.bin" 2>"$D/err"
    if [ $? -ne 0 ]; then
        echo "FAIL $name: $(cat "$D/err")"
        fail=1
        return
    fi
    "$D/out.bin"
    local got=$?
    if [ "$got" = "$want" ]; then
        echo "ok   $name (exit $got)"
    else
        echo "FAIL $name: exit $got, wanted $want"
        fail=1
    fi
}

# included text SHORTER than the directive line it replaces (tail shifts left)
printf 'mov rdi, 7\n' > "$D/short.v0"
printf '%%include "%s/short.v0"\nmov rax, 60\nsyscall\n' "$D" > "$D/m1.v0"
expect_exit "include shorter than directive" 7 "$D/m1.v0"

# included text LONGER than the directive (tail shifts right)
{ echo "; padding to make this file long"; echo "; padding"; echo "; padding"
  echo "mov rdi, 8"; } > "$D/long.v0"
printf '%%include "%s/long.v0"\nmov rax, 60\nsyscall\n' "$D" > "$D/m2.v0"
expect_exit "include longer than directive" 8 "$D/m2.v0"

# include is the entire program (no tail at all)
printf 'mov rax, 60\nmov rdi, 9\nsyscall\n' > "$D/whole.v0"
printf '%%include "%s/whole.v0"\n' "$D" > "$D/m3.v0"
expect_exit "include is the whole program" 9 "$D/m3.v0"

# nested includes
printf 'mov rdi, 10\n' > "$D/inner.v0"
printf '%%include "%s/inner.v0"\nmov rax, 60\n' "$D" > "$D/outer.v0"
printf '%%include "%s/outer.v0"\nsyscall\n' "$D" > "$D/m4.v0"
expect_exit "nested includes" 10 "$D/m4.v0"

# a missing file must be a clean error
printf '%%include "%s/nope.v0"\n' "$D" > "$D/m5.v0"
$V "$D/m5.v0" "$D/out.bin" 2>"$D/err"
[ $? -ne 0 ] && echo "ok   missing include rejected: $(cat "$D/err")" \
             || { echo "FAIL missing include accepted"; fail=1; }

# a file including itself must terminate, not exhaust memory
printf '%%include "%s/self.v0"\n' "$D" > "$D/self.v0"
$V "$D/self.v0" "$D/out.bin" 2>"$D/err"
[ $? -ne 0 ] && echo "ok   self-include rejected: $(cat "$D/err")" \
             || { echo "FAIL self-include accepted"; fail=1; }

exit $fail
