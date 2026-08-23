#!/usr/bin/env bash
# check_smoke.sh -- the README's first line, on its own, before anything
# else runs.
#
#   ./v1 program.v0 program && ./program
#
# That invocation is exercised by nearly every other test here, and was
# still broken for a whole release: a register holding the worker count
# did not survive a stat syscall, so the startup path asked the kernel
# for 16 GiB of shared memory. On a machine with room to overcommit, the
# mapping succeeded, was never touched, and every test passed. On one
# without, every single argv-form run died with "mmap failed".
#
# So the run under a constrained address space is the point of this file,
# not decoration: it is what makes an absurd-but-satisfiable allocation
# fail loudly instead of being absorbed. The limit is generous next to
# what a real assembly needs and impossible for a bug of that shape.
cd "$(dirname "$0")/.."
V=${1:-./v1}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
fail=0

printf 'mov rax, 60\nmov rdi, 42\nsyscall\n' > "$D/p.v0"

if $V "$D/p.v0" "$D/p" 2>"$D/e"; then
    "$D/p"; rc=$?
    [ "$rc" = 42 ] && echo "ok   argv form: assembled, ran, exit 42" \
        || { echo "FAIL argv form: exit $rc"; fail=1; }
else
    echo "FAIL argv form: $(cat "$D/e")"; fail=1
fi

if $V < "$D/p.v0" > "$D/p2" 2>"$D/e"; then
    chmod +x "$D/p2"; "$D/p2"; rc=$?
    [ "$rc" = 42 ] && echo "ok   stdin/stdout form: exit 42" \
        || { echo "FAIL stdin/stdout form: exit $rc"; fail=1; }
else
    echo "FAIL stdin/stdout form: $(cat "$D/e")"; fail=1
fi

# 2 GiB is far more than any of these need and far less than a startup
# path with a clobbered worker count would ask for.
if ( ulimit -v 2097152; $V "$D/p.v0" "$D/p3" ) 2>"$D/e"; then
    echo "ok   argv form inside a 2 GiB address space"
else
    echo "FAIL argv form needs more than 2 GiB of address space: $(cat "$D/e")"
    fail=1
fi
if ( ulimit -v 2097152; $V "$D/p.v0" "$D/p4" 4 ) 2>"$D/e"; then
    echo "ok   argv form with -j4 inside a 2 GiB address space"
else
    echo "FAIL -j4 needs more than 2 GiB of address space: $(cat "$D/e")"
    fail=1
fi

exit $fail
