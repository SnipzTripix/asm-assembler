#!/usr/bin/env bash
# check_cli.sh -- the command line refuses what it cannot do.
#
# Every case here used to be accepted silently. An unknown flag was
# treated as an input filename, so `-x in.v0 out` reported "could not
# open input or output file" and sent the reader to look at the file. A
# worker count that was not a number fell out of the digit loop at the
# first non-digit and quietly became 1 or a truncated value, so a typo in
# a build script turned a parallel build serial with nothing said.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0
printf 'mov rax, 60\nmov rdi, 0\nsyscall\n' > "$D/p.v0"

bad() {  # bad <name> <args...>
    local name="$1"; shift
    if $V "$@" 2>"$D/e" >/dev/null; then
        echo "FAIL $name: accepted"; fail=1
    else
        echo "ok   $name -- $(head -1 "$D/e")"
    fi
}
good() { # good <name> <args...>
    local name="$1"; shift
    if $V "$@" 2>"$D/e" >/dev/null; then
        echo "ok   $name"
    else
        echo "FAIL $name: $(head -1 "$D/e")"; fail=1
    fi
}

bad  "unknown flag"        -x "$D/p.v0" "$D/o"
bad  "misspelled -f"       -F elf64 "$D/p.v0" "$D/o"
bad  "unknown format"      -f coff "$D/p.v0" "$D/o"
bad  "non-numeric jobs"    "$D/p.v0" "$D/o" abc
bad  "negative jobs"       "$D/p.v0" "$D/o" -1
bad  "zero jobs"           "$D/p.v0" "$D/o" 0
bad  "fractional jobs"     "$D/p.v0" "$D/o" 3.5
bad  "trailing garbage"    "$D/p.v0" "$D/o" 4x

good "plain in/out"        "$D/p.v0" "$D/o"
good "explicit -j1"        "$D/p.v0" "$D/o" 1
good "jobs above MAX_JOBS" "$D/p.v0" "$D/o" 999999
good "-f elf64"            -f elf64 "$D/p.v0" "$D/o.o"

exit $fail
