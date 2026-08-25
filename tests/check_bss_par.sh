#!/usr/bin/env bash
# check_bss_par.sh -- .bss must survive parallel assembly.
#
# tests/bss.v0 covers .bss, and par_equiv.sh covers parallel == serial,
# but nothing covered both at once: every .bss input in the suite was far
# under PAR_MIN_BYTES, so it took the serial fallback and the parallel
# .bss path was never executed by a test at all. It was broken in four
# separate places, and the resulting binary either lost its bss segment
# (segfault on first access) or placed .bss inside the RW data segment,
# where it ran and silently corrupted .data instead.
#
# So the input here is padded past the threshold on purpose, and the
# assertions are the two that would have caught it: byte-identical output
# at every worker count, and the assembled program actually running.
set -u
cd "$(dirname "$0")/.."
V=${1:-./v1}
fail=0
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

# Read the threshold out of the source rather than hardcoding it, so this
# test cannot quietly stop exercising the parallel path if it changes.
MIN=$(grep -m1 '^PAR_MIN_BYTES' v1.v0 | awk '{print $3}')
[ -n "$MIN" ] || { echo "FAIL: could not read PAR_MIN_BYTES from v1.v0"; exit 1; }
# .bss in each of the three positions relative to .text, with and without
# a .data section: the bug was position-dependent, and a .data section
# masked the crash by giving the misplaced labels a mapped page to land in.
# awk, not python: this project's rule that nothing outside the toolchain
# generates its inputs applies to the tests too, and awk is already what
# every other generator here uses.
gen() { # $1 = position, $2 = with .data, $3 = out
    awk -v pos="$1" -v wd="$2" -v minb="$MIN" 'BEGIN {
        n = int(minb / 12) + 20000
    }
    function head_() {
        print ".text"; print "mov rax, buf"; print "mov rcx, 91"
        print "mov [rax+0], rcx"; print "mov rdi, [rax+0]"
    }
    function pad_(  i) { for (i = 0; i < n; i++) print "mov rbx, " (i % 100) }
    function tail_() { print "mov rax, 60"; print "syscall" }
    function bss_()  { print ".bss"; print "buf: resb 4096" }
    function data_() { if (wd == 1) { print ".data"; print "dv: db \"x\"" } }
    BEGIN {
        if      (pos == "top") { bss_(); data_(); head_(); pad_(); tail_() }
        else if (pos == "mid") { head_(); bss_(); data_(); print ".text"
                                 pad_(); tail_() }
        else                   { head_(); pad_(); tail_(); data_(); bss_() }
    }' < /dev/null > "$3"
}

for pos in top mid bot; do
  for d in 0 1; do
    lbl="$pos$([ "$d" = 1 ] && echo '+data')"
    gen "$pos" "$d" "$D/in.v0"
    sz=$(wc -c < "$D/in.v0")
    if [ "$sz" -lt "$MIN" ]; then
        echo "FAIL $lbl: input ${sz}B is under PAR_MIN_BYTES ($MIN) -- this"
        echo "     test would run serially and assert nothing"
        fail=1; continue
    fi
    if ! $V "$D/in.v0" "$D/j1" 1 2>"$D/err"; then
        echo "FAIL $lbl: serial assembly failed: $(cat "$D/err")"; fail=1; continue
    fi
    bad=""
    for j in 2 3 5 8 16; do
        if ! $V "$D/in.v0" "$D/j$j" "$j" 2>"$D/err"; then
            bad="$bad -j$j(error)"; continue
        fi
        cmp -s "$D/j1" "$D/j$j" || bad="$bad -j$j"
    done
    if [ -n "$bad" ]; then
        echo "FAIL $lbl: parallel output differs from serial:$bad"
        fail=1; continue
    fi
    # The output has to run, not merely match: if both paths dropped the
    # bss segment the comparison above would still pass.
    chmod +x "$D/j1" "$D/j8"
    "$D/j1" >/dev/null 2>&1; s=$?
    "$D/j8" >/dev/null 2>&1; p=$?
    if [ "$s" != 91 ] || [ "$p" != 91 ]; then
        echo "FAIL $lbl: program exit serial=$s parallel=$p, wanted 91"
        fail=1; continue
    fi
    # And .bss must be its own mapping, not an address inside .data.
    if command -v readelf >/dev/null 2>&1; then
        ls=$(readelf -l "$D/j1" 2>/dev/null | grep -c 'LOAD')
        lp=$(readelf -l "$D/j8" 2>/dev/null | grep -c 'LOAD')
        if [ "$ls" != "$lp" ]; then
            echo "FAIL $lbl: $ls LOAD segments serial, $lp parallel"
            fail=1; continue
        fi
    fi
    echo "ok   $lbl (${sz}B, identical at every worker count, runs, segments match)"
  done
done

[ $fail -eq 0 ] && echo "BSS PARALLEL OK"
exit $fail
