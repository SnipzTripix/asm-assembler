#!/usr/bin/env bash
# check_layout.sh -- the memory map is a set of hand-picked absolute
# offsets into one mmap. Nothing enforces that they do not collide.
#
# That is not hypothetical. OUTPATH_OFF was placed at 0xD8000A0, which is
# exactly where chunk 1 of the parallel chunk table starts, so every
# parallel run had worker 1 overwrite the output path and every -j>=2
# build died. It took a bug report to find, because a wrong address in a
# flat address space corrupts something unrelated rather than faulting.
#
# Every other correctness property here has a mechanical check behind it
# -- the fixed point for the encoder, the differential test for the
# encodings, the rejection suite for the parser. This is the one for the
# layout: it reads the declared regions out of v1.v0 and asserts that no
# two of them overlap and that all of them fit inside MMAP_TOTAL.
#
# A region is "NAME_OFF equ ADDR" plus a size. Sizes come from an
# adjacent NAME_CAP where one exists, and otherwise from the table below,
# which has to be maintained by hand -- a scalar slot is 8 bytes, an
# array is its entry size times its capacity. Anything not listed is
# assumed to be a single 8-byte slot, which is the common case and the
# conservative one: under-stating a size can only miss a collision, never
# invent one.
cd "$(dirname "$0")/.."
SRC=v1.v0
fail=0

val() {   # val NAME -> the integer value of `NAME equ ...`, or empty
    awk -v n="$1" '$1 == n && $2 == "equ" { print $3; exit }' "$SRC" \
        | sed 's/;.*//' | tr -d ' \r'
}
num() {   # num LITERAL -> decimal
    case "$1" in 0x*|0X*) printf '%d' "$1" ;; '') echo '' ;; *) echo "$1" ;; esac
}

# name:size-expression. Multi-entry regions state their real extent.
REGIONS="
INBUF_OFF:BUF_LEN
TEXTBUF_OFF:0x4000000
DATABUF_OFF:0x1000000
BSSBUF_OFF:0x1000000
SYMTAB_OFF:SYM_CAP*SYM_ENT
FIXUPS_OFF:FIX_CAP*FIX_ENT
CHUNKTAB_OFF:MAX_JOBS*CHUNK_ENT
DEFLIST_OFF:0x800000
PAR_FILTER_OFF:0x10000
PAR_CONST_OFF:PAR_CONST_CAP*PAR_CONST_ENT
INCBUF_OFF:INCBUF_CAP
OBJ_SYM_OFF:0x800000
OBJ_STR_OFF:OBJ_STR_CAP
OBJ_RELT_OFF:0x800000
OBJ_RELD_OFF:0x800000
OBJ_SHDR_OFF:0x1000
OBJ_ZERO_OFF:0x1000
STATBUF_IN_OFF:144
STATBUF_OUT_OFF:144
"

total=$(num "$(val MMAP_TOTAL)")
[ -n "$total" ] || { echo "FAIL: no MMAP_TOTAL in $SRC"; exit 1; }

# Collect every *_OFF that names an address inside the arena, sized from
# the table above where listed and 8 bytes otherwise.
names=$(grep -oE '^[A-Z0-9_]+_OFF' "$SRC" | sort -u)
list=""
for n in $names; do
    a=$(num "$(val "$n")")
    case "$a" in ''|*[!0-9]*) continue ;; esac
    [ "$a" -ge 0 ] 2>/dev/null || continue
    sz=8
    for r in $REGIONS; do
        case "$r" in "$n":*)
            expr=${r#*:}
            case "$expr" in
                *\**) l=$(num "$(val "${expr%%\**}")"); rr=$(num "$(val "${expr##*\*}")")
                      [ -n "$l" ] || l=${expr%%\**}; [ -n "$rr" ] || rr=${expr##*\*}
                      sz=$((l * rr)) ;;
                0x*)  sz=$(num "$expr") ;;
                [0-9]*) sz=$expr ;;
                *)    v=$(num "$(val "$expr")"); [ -n "$v" ] && sz=$v ;;
            esac ;;
        esac
    done
    list="$list$a $sz $n
"
done

echo "$list" | grep -v '^$' | sort -n > /tmp/layout.$$
prev_end=0; prev_name=""
while read -r a sz n; do
    end=$((a + sz))
    if [ "$a" -lt "$prev_end" ]; then
        printf 'FAIL: %s (0x%X) starts inside %s, which ends at 0x%X\n' \
               "$n" "$a" "$prev_name" "$prev_end"
        fail=1
    fi
    if [ "$end" -gt "$total" ]; then
        printf 'FAIL: %s ends at 0x%X, past MMAP_TOTAL 0x%X\n' "$n" "$end" "$total"
        fail=1
    fi
    if [ "$end" -gt "$prev_end" ]; then prev_end=$end; prev_name=$n; fi
done < /tmp/layout.$$
n=$(wc -l < /tmp/layout.$$)
rm -f /tmp/layout.$$

[ $fail -eq 0 ] && echo "ok   $n regions, none overlapping, all inside MMAP_TOTAL"
exit $fail
