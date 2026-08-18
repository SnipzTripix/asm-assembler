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
- `push pop`, `jmp je jne jl jae`, `call` (label *or* register), `ret`,
  `syscall`
- `db` with `\n \t \r \0 \\ \"` escapes, `dw`/`dd`/`dq` — and `dq label`,
  which together with `call reg` makes a function-pointer dispatch table
  expressible
- `equ` constants (a number, a negative number, or the name of a
  constant already defined, so `B equ A` aliases), `label:` definitions,
  `resb`
- memory operands `[base+disp]` and `[base+index*scale+disp]`
- `.text`/`.data`/`.bss` — real ELF segments: R+X, R, and a
  zero-filled RW mapping that costs nothing in the file
- `%include "file"`, nesting supported
- filenames as argv[1]/argv[2], worker count as argv[3]

Not yet implemented: arithmetic at widths other than 64-bit (memory
access has `movb`/`movw`/`movd`; the ALU ops are always full-width),
RIP-relative addressing, the remaining `jcc` conditions, and short
(`rel8`) jumps.

`rel8` is a deliberate omission. Picking it requires knowing whether the
target is within 127 bytes, which isn't known when the instruction is
emitted — so it needs a relaxation loop: shrink a jump, watch every later
address shift, repeat to a fixed point. That is exactly what the
single-pass design trades away, and it's why forward references need no
second parse. It belongs behind an optimisation flag, not in the default
path.

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

Measured on a 16-thread i5-13400F, warm cache, output to `/dev/null`,
on a generated 3.83 MB source (`tests/par_scaling.sh`):

| Workers | Wall | CPU/wall | Throughput |
|---|---|---|---|
| `-j1` | 34 ms | 0.97 | 113 MB/s |
| `-j2` | 26 ms | 1.5 | 147 MB/s |
| `-j4` | 18 ms | 2.1 | 213 MB/s |
| `-j8` | 16 ms | 2.6 | 239 MB/s |
| `-j16` | 15 ms | 3.2 | **255 MB/s** |

Files under 256 KB ignore the worker count and run serially — below that
size, forking and merging cost more than they save. That threshold is
also why the earlier numbers in this table were wrong: every test input
was under it, so the "parallel" tests had been measuring (and checking)
the serial path. `tests/par_equiv.sh` now reads the threshold out of the
source, generates an input past it, and asserts that CPU time exceeds
wall time — something a serial fallback cannot fake.

The ceiling is Amdahl, not contention: a serial pre-pass has to run
first (it finds chunk boundaries, and resolves the two things that
genuinely flow forward through a file — the current section and the `equ`
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

On a 100k-line / 1.25 MB source file: ~18 ms.

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
the assembler *emits* — a fixed point, a 3504-instruction cross product
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

The differential test against GNU `as` is what backs this up. It runs in
two forms: a hand-written file covering every instruction form, and
`tests/gen_difftest.sh`, which generates the full cross product — every
ALU op across all 16×16 register pairs, every memory form across all
bases, indices and scales, every unary form across all 16 registers,
3504 instructions in total — and requires all 17250 bytes to match.
Generating it rather than hand-writing it is what turns "no known
encoding bugs" into "no encoding bugs in the tested space", and it is
what makes changing the encoder safe.

It has caught real defects, including a redundant REX prefix on every
low-register `movd`/`movw`, found the day it was reconnected.
