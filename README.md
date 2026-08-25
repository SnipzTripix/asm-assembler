# asm — an x86-64 assembler written in x86-64 assembly

`v1` assembles x86-64 assembly source into flat ELF64 executables. It is
written entirely in the dialect it itself implements, has no dependency
on any other assembler, and reproduces itself byte-for-byte when it
assembles its own source (`v1.v0`) — the project's fixed-point test.

```
./v1 v1.v0 v1_next && cmp v1 v1_next   # byte-identical
```

No libc, no dynamic linker, no external tools at runtime — every OS
interaction is a direct `syscall`.

## Quick start

```
./v1 program.v0 program && ./program        # argv-based
./v1 < program.v0 > program && chmod +x program && ./program   # stdin/stdout
./v1 -f elf64 program.v0 program.o && ld -o program program.o  # object file
```

`program.v0` is written in the dialect described below. The output is a
runnable ELF64 executable (argv-based invocation sets the output file's
mode to 0755 automatically; the stdin/stdout form needs an explicit
`chmod +x`).

## Layout

| Path | What |
|---|---|
| `v1.v0` | The assembler's own source, in its own dialect |
| `v1` | The assembler's own binary, built from `v1.v0` |
| `seed/` | Retired bootstrap tool (see below) — not needed to build anything |
| `tests/` | Regression programs, nasm differential tests, a benchmark generator |

## The bootstrap story

`v1` didn't come from nowhere. `seed/seed.asm` is a small, hand-verified
assembler — every opcode byte checked against the Intel SDM in a
comment, assembled once with `nasm` the way a hex editor would be used,
not because nasm chose any encoding for it. `seed` understood just enough
of the dialect (`mov`, `syscall`, `ret`, labels, a handful of arithmetic
and jump forms) to assemble a first version of `v1.v0`. From there, `v1`
grew by assembling improved versions of its own source — more
instructions, a real symbol table, `.text`/`.data` sections — each change
verified two ways before being kept:

1. **Differential testing against nasm** (`tests/run_difftest.sh`) — the
   same instruction forms, assembled by both, compared byte-for-byte.
2. **The fixed-point check** — `v1` assembling its own current source
   must reproduce its own current binary exactly. If it doesn't, the bug
   is in the encoder, not the source (this caught several real ones: a
   register-field corruption from a clobbered scratch register, a
   32-bit truncation that silently corrupted any constant whose value
   didn't fit in 32 bits, a couple of stale mnemonics left over from
   dialect changes).

`seed` is kept, unmodified, purely as the historical record and as a
second independent encoder to differential-test against — nothing in
`v1` depends on it anymore. See `seed/README.md`.

## The dialect

Line-oriented, one statement per line, Intel-syntax operand order
(`op dst, src`). Full current instruction set and known gaps are
documented at the top of `v1.v0` — that comment is kept up to date as
the dialect grows, so it's the source of truth, not this file. Briefly:

- `mov`/`movb`/`movw`/`movd` (64/8/16/32-bit, register/immediate/memory,
  label addresses), `lea`, `imul`, `neg`
- `add sub and or xor cmp test` (reg,reg and reg,imm; immediates may be
  negative and are range-checked), `shl shr`
- `push pop`, `ret`, `syscall`, `call` and `jmp` (each taking a label
  *or* a register — the register form is the near indirect `FF /digit`),
  and `Jcc` in all sixteen conditions (`jo jno jb jae je jne jbe ja js
  jns jp jnp jl jge jle jg` — canonical names only, no `jz`/`jc`
  aliases)
- `db` with `\n \t \r \0 \\ \"` escapes, `dw`/`dd`/`dq` — and `dq label`,
  which together with `call reg` makes a function-pointer dispatch table
  expressible
- `equ` constants (a number, a negative number, or the name of a
  constant already defined, so `B equ A` aliases), `label:` definitions,
  `resb`
- memory operands `[base+disp]` and `[base+index*scale+disp]`
- `.text`/`.data`/`.bss` — real ELF segments: R+X, RW, and a
  zero-filled RW mapping that costs nothing in the file. `.bss` takes
  only `resb`, labels and `equ`: it contributes no file bytes, so a
  `db` or an instruction there is an error rather than a byte that
  silently disappears
- `%include "file"`, nesting supported
- `global NAME` / `extern NAME` for object output
- `[-f elf64]`, then filenames, then a worker count

Not yet implemented: 32/16/8-bit register operands (`mov eax, ebx` is a
syntax error) and ALU ops at any width but 64 (memory access has
`movb`/`movw`/`movd`, but `add eax, 1` is unexpressible), RIP-relative
addressing, and short (`rel8`) jumps. That first one is the wall between
this and assembling compiler output.

`rel8` is a deliberate omission. Picking it requires knowing whether the
target is within 127 bytes, which isn't known when the instruction is
emitted — so it needs a relaxation loop: shrink a jump, watch every later
address shift, repeat to a fixed point. That is exactly what the
single-pass design trades away, and it's why forward references need no
second parse. It belongs behind an optimisation flag, not in the default
path.

Memory displacements are the opposite case, and used to be lumped in
with `rel8` by mistake. A displacement is a *constant*, fully known at
the moment the instruction is emitted, so choosing the shortest form
moves nothing and needs no second pass. `[rbx]` is three bytes, not
seven; `[rbx+8]` uses `disp8`; `rbp`/`r13` bases still carry an explicit
zero because `mod=00` means something else for them. Every one of those
choices is checked against GNU `as` across all 16 bases, four index
registers and the values `0, ±1, ±127, ±128, ±129, 255, -32768` — the
boundaries where the `mod` bits and the `rbp`/`rsp` escapes interact.

## Object files

```
./v1 -f elf64 a.v0 a.o
./v1 -f elf64 b.v0 b.o
ld -o prog a.o b.o
```

Without this, `v1` was a fast and careful assembler for a language only
this project writes: its output had no section headers, no symbols and
no relocations, so `ld` could not link it, `nm` and `objdump` had nothing
to read, and multi-file projects meant textual `%include`. `-f elf64`
emits a normal `ET_REL` object — `.text`/`.data`/`.bss`,
`.symtab`/`.strtab`, `.rela.text`/`.rela.data` — that links against
objects from other assemblers, and vice versa.

`global NAME` exports a symbol; `extern NAME` says it lives elsewhere, so
a reference becomes a relocation instead of an error. `extern` is refused
for flat output rather than ignored: a flat binary has no relocations, so
the reference could only ever resolve to address zero.

Most of this already existed. Labels have carried a section-relative
value and a section id since sections were added, fixups already record
which section they patch and which symbol they want, and the list of
declared symbols is already kept in source order — so nothing has to be
sorted, and symbol and relocation order is deterministic for free. What
is new is the file layout and the decision *not* to resolve label
fixups, which is what makes the output relocatable.

Two things deliberately don't appear. `equ` constants are compile-time
values rather than addresses, so a fixup naming one is still resolved in
place — emitting them as `SHN_ABS` symbols would invite a linker to
relocate a number. And there is no debug information at all: `nm` and
`objdump -dr` work, `gdb` will not show you a source line.

The strongest test of it is that the assembler survives a round trip
through somebody else's linker:

```
./v1 -f elf64 v1.v0 v1.o && ld -e start -o v1_linked v1.o
./v1_linked v1.v0 out && cmp out v1     # byte-identical
```

## Parallel assembly

`v1` can assemble one file across multiple cores. Pass a worker count as
the third argument:

```
./v1 big.v0 big.out 8
```

The output is **byte-identical no matter how many workers are used** —
`tests/par_equiv.sh` asserts exactly that for every test input at every
worker count, and it is the reason the feature is trustworthy at all.

Each worker is a `fork`ed process, so it gets a copy-on-write clone of
the address space and runs the ordinary, unmodified assembler over its
own slice of the source. Nothing is shared and nothing is locked — the
only shared memory is one result slot per worker, which only that worker
writes and which the parent reads only after `wait4` says the worker is
gone. Chunks are merged in index order, never completion order, so
scheduling cannot affect the result.

Measured on a 32-thread i9-13900KS, warm cache, output to `/dev/null`,
on a generated 3.83 MB / 300,003-statement source
(`tests/par_scaling.sh`). Earlier revisions of this table were taken on
a 16-thread i5-13400F; the whole table was re-measured on the new
machine rather than scaled:

| Workers | Wall | CPU/wall | Throughput |
|---|---|---|---|
| `-j1` | 28 ms | 0.96 | 137 MB/s |
| `-j2` | 22 ms | 1.5 | 174 MB/s |
| `-j4` | 15 ms | 1.9 | 255 MB/s |
| `-j8` | 13 ms | 2.6 | 294 MB/s |
| `-j16` | 12 ms | 3.1 | **319 MB/s** |

`-j16` is where the table stops because `MAX_JOBS` is 16 and the worker
count is clamped to it. An earlier version of this file called raising
that clamp "the obvious fix" for the plateau. It isn't, and the numbers
say so: measured on a 12.8 MB / 1M-statement input, `-j32` is identical
to `-j16`, and the Amdahl split from the `-j8`/`-j16` pair is ~29 ms
serial against ~37 ms parallel — **43% serial**, so the ceiling is 2.3×
and the measurement is already 2.1× of it. Raising the clamp buys about
a millisecond.

The serial 29 ms is the pre-pass and the merge. That is what has to
shrink, and most of the pre-pass does not actually need to be serial:
chunk boundaries and section state can be found by a parallel scan, and
only `equ` values genuinely flow forward through a file. Until that is
done the worker count is not the limit and there is no point pretending
otherwise.

Files under 256 KB ignore the worker count and run serially — below that
size, forking and merging cost more than they save. That threshold is
also why the earlier numbers in this table were wrong: every test input
was under it, so the "parallel" tests had been measuring (and checking)
the serial path. `tests/par_equiv.sh` now reads the threshold out of the
source, generates an input past it, and asserts that CPU time exceeds
wall time — something a serial fallback cannot fake.

That threshold guards against small files, not against unhelpful
shapes. On a source of 400,000 `jmp END` against a single label at the
end of the file — every reference deferred to the merge, and almost no
encoding work for a worker to do — `-j` is a **pessimisation**: 13 ms at
`-j1` against 21 ms at `-j16`, best of five, warm. The merge's per-fixup
work is the whole cost and the workers have nothing to amortise it
against. It is the shape, not the deferral: 200,000 jumps to 200,000
*distinct* far labels scale normally (53 ms → 14 ms), because there the
symbol table work is real and parallel. Ordinary code looks like the
second, not the first. The fix is a cheaper merge rather than a cleverer
threshold, and until there is one, `-j` on reference-dense input with a
tiny symbol table costs more than it saves.

The ceiling is Amdahl, not contention, and it is measured rather than
asserted: ~43% of the work is serial. A serial pre-pass has to run first
(it finds chunk boundaries, and resolves the two things that genuinely
flow forward through a file — the current section and the `equ`
constants), and a serial merge has to stitch the pieces back together.
Two optimisations do most of the work of keeping those cheap: workers
resolve every reference that lands inside their own chunk (nearly all
jumps and calls), and the merge installs only those labels some deferred
reference actually asks for, filtered by a hash lookup.

## Performance

Symbol lookup is an FNV-1a open-addressed hash table (was a linear scan
until it was measured to be the actual bottleneck: 55x slower on a
100k-line file with 10,000 labels). Mnemonic dispatch is a masked-qword
(SWAR) compare bucketed by first letter, not a byte-by-byte string
comparison. Register names go through the same masked compare, ordered
by how often each register actually occurs — it was a linear walk of an
11-byte-stride table calling a byte-loop comparison per entry, so
recognising `r15` cost sixteen function calls and every label operand
paid all sixteen before being rejected. Character classification is a
branchless 256-byte lookup table.

On a 100k-line / 1.25 MB source file: ~15 ms (i9-13900KS).

One caveat on all of these, learned the expensive way. This binary's
statement loop is sensitive to where it lands in memory: adding ~300
bytes of unrelated code elsewhere in `.text` moved self-assembly by 26%,
and a *seven-byte* shift was enough to hold the difference. That is a hot
loop crossing a 32-byte boundary, and the dialect has no `align`
directive to pin it with — so any measurement of a change smaller than
that is measuring placement, not the change. Two consequences worth
stating: benchmark warmed and interleaved (a cold-cache run showed one
change as a 19% win that warmed runs showed as a 19% loss), and treat
sub-30% differences here as unattributable until `align` exists.

Against the assemblers it is not trying to replace, same 3.83 MB /
300,003-statement input, best of three:

| | Wall | vs `v1 -j1` |
|---|---|---|
| `v1 -j16` | 11 ms | 2.5× |
| `v1 -j1` | 27 ms | 1× |
| GNU `as` | 254 ms | 9.4× slower |
| `nasm -f elf64` | 1062 ms | 39× slower |
| `nasm -f bin` | 1310 ms | 48× slower |

Worth stating plainly what that does and does not show. It is a real,
reproducible measurement of the same instructions through each tool, and
it is not apples to apples: both references carry a macro preprocessor,
an expression evaluator and multiple output formats that this input
never exercises and `v1` does not have at all. Quoting only the nasm
number would also flatter the result — GNU `as` is four to five times
faster than nasm here, and it is the more honest comparison of the two.

Two notes on measuring any of this, both learned the hard way:

- The benchmark generator used to emit only `rax`/`rbx`/`rcx`/`rdx`,
  which were the first four entries of the old register table. Rewriting
  register parsing made register-dense code 1.9x faster and moved the
  benchmark by nothing at all. It emits a spread across all 16 registers
  now, and shows 1.25x on the same change.
- The first-letter bucket chain in mnemonic dispatch was going to become
  a `dq label` jump table until it was measured: the difference between
  the first bucket and the last, on 200k statements, is about 2.5 ns per
  statement. An indirect branch across fourteen targets would likely
  have cost more than the compares it replaced. It stayed a chain.

```
tests/gen_big.sh 10000 > /tmp/big.v0
time ./v1 < /tmp/big.v0 > /dev/null
```

## Building from source

The whole chain rebuilds from `seed.asm` with `nasm` as the only trusted
input:

```
./bootstrap.sh
```

```
nasm    seed.asm -> seed
seed    v1.v0    -> stage1
stage1  v1.v0    -> stage2
stage2  v1.v0    -> stage3      require stage2 == stage3
```

`stage2 == stage3` is the proof that matters: stage2 came from a compiler
built from source, so its reproducing itself means the whole chain is
reproducible from `seed.asm`. The committed `v1` binary is then compared
against stage2 — which makes it a convenience rather than a dependency,
and proves it. (stage1 is deliberately *not* compared: seed is a cruder
assembler and emits an equivalent but different binary; only from stage2
on is the output self-hosted.)

## Running the tests

```
tests/run_all.sh          # everything
```

That covers: each `tests/*.v0` program (assembled, run, exit status
checked), the range/overflow regressions, the self-hosting fixed point,
and — if `nasm` happens to be installed — the differential test against
it. `nasm` is only needed for that last one; `v1` itself has no build or
runtime dependencies at all beyond a Linux kernel, so the suite still
runs (and reports the differential test as skipped) on a machine with no
toolchain installed.

The pieces can also be run alone: `tests/fixedpoint.sh`,
`tests/regress_range.sh`, `tests/run_difftest.sh`. `tests/probe.sh` is a
non-asserting diagnostic — it throws malformed and edge-case input at
the assembler and prints what happens, which is how the range bugs above
were found in the first place; `tests/check_reject.sh` is the asserting
half of the same idea, and lists every input the assembler must refuse.

That distinction turned out to matter. The suite was thorough about what
the assembler *emits* — a fixed point, a 7220-instruction cross product
against GNU `as` — and had nothing at all about what it should *refuse*,
which is precisely the shape of the bugs it kept missing: input that
assembles cleanly into the wrong program. Three other scripts were
printing "DIFFERS" or "race condition" and exiting 0, so `run_all.sh`
scrolled past them green; they assert now.

## Correctness stance

A wrong encoding that still runs is the worst thing an assembler can do,
so values that don't fit their target field are hard errors with a line
and column, never silent truncation:

```
$ printf 'add rax, 0x123456789\n' | ./v1
v1: immediate out of range at line 1 col 21
```

The same applies to memory displacements wider than `disp32`, integer
literals that overflow 64 bits, shift counts above 63, operands too wide
for the `db`/`dw`/`dd` slot they are headed for, unknown string escapes,
and bad index scales.

A statement must also end where its line does. The dialect has no
expressions and no comma-separated operand lists, so input that assumes
otherwise is rejected rather than half-assembled:

```
$ printf 'mov rdi, 4+2\n' | ./v1
v1: bad operand at line 1 col 11
```

Each of those used to be accepted: `4+2` emitted 4, `db 1, 2, 3` emitted
one byte, `mov rax, rbx rcx` dropped the third word. Nothing was reported
because nothing was wrong at the point the operands parsed — the evidence
was entirely in the text that came after, which the old statement tails
skipped without reading. An undefined label names the symbol instead of a position, since
it is only discovered once the whole file has been scanned:

```
v1: undefined label: nowhere_at_all
```

Every error path exits nonzero with a distinct message on stderr — there
are no assertion failures or segfaults on malformed input.

Two invariants that have no natural test and so have an artificial one:

- **Register discipline.** `syscall` overwrites `rcx` and `r11` — that's
  the instruction, not the kernel — so any routine that might issue one
  destroys them, whether or not that's visible at the call site. The same
  mistake has now caused three separate bugs: a job count in `r11` across
  `mmap` that became a fork bomb, a byte count in `r11` across `read`
  that padded a buffer with NULs, and a job count in `r11` across an
  `fstat` that asked for 16 GiB of shared memory and broke `./v1 in out`
  on any machine that couldn't overcommit it. The convention is now
  stated once at the top of `v1.v0`, and `tests/check_smoke.sh` runs the
  documented invocations inside a 2 GiB address space — generous for a
  real assembly, impossible for a bug of that shape.
- **Memory layout.** Every region is a hand-picked absolute offset into
  one mapping, and a wrong address there corrupts something unrelated
  instead of faulting. `tests/check_layout.sh` reads the declared regions
  out of `v1.v0` and asserts none overlap and all fit. It found two live
  collisions the first time it ran: the last symbol slot's final field
  sat on the fixup counter, and the last prescan constant's value sat on
  the line-start pointer.

The differential test against GNU `as` is what backs this up. It runs in
two forms: a hand-written file covering every instruction form, and
`tests/gen_difftest.sh`, which generates the full cross product — every
ALU op across all 16×16 register pairs, every memory form across all
bases, indices and scales, every unary form across all 16 registers,
7220 instructions in total, including displacement boundaries, every
immediate encoding and all sixteen jump conditions
— and requires all 27954 bytes to match.
Generating it rather than hand-writing it is what turns "no known
encoding bugs" into "no encoding bugs in the tested space", and it is
what makes changing the encoder safe.

It has caught real defects, including a redundant REX prefix on every
low-register `movd`/`movw`, found the day it was reconnected.
