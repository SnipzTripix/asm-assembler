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
  label addresses), `lea`, `imul` (reg,reg)
- `add sub and or xor cmp test` (reg,reg and reg,imm — `test` is
  reg,reg only — immediates may be negative), `neg`, `shl shr`
- `push pop`, `jmp je jne jl jae call ret syscall`
- `db` (string or byte literal), `equ` (compile-time constants),
  `label:` definitions, `.text`/`.data` (real ELF sections — separate
  R+X and R `PT_LOAD` segments, not one flat blob)
- filenames as argv[1]/argv[2] (falls back to stdin/stdout)

Not yet implemented: `imul reg,imm`, `test reg,imm`, `.bss`, arithmetic
narrower than 64 bits (memory access has `movb`/`movw`/`movd`; the ALU
ops don't), scaled-index or RIP-relative addressing, short (`rel8`) jump
encoding.

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

Measured on a 16-thread i5-13400F, best of 7, output to `/dev/null`:

| Input | `-j1` | `-j16` | Speedup |
|---|---|---|---|
| 100k lines (1.3 MB) | 18.7 ms | 7.1 ms | **2.63×** |
| 1M lines (13 MB) | 78.8 ms | 34.3 ms | **2.29×** |

That is ~180 MB/s and ~380 MB/s of source respectively. Files under
256 KB ignore the worker count and run serially — below that size,
forking and merging cost more than they save.

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
comparison. Character classification is a branchless 256-byte lookup
table. On a 100k-line / ~1.3MB source file: ~20ms, comfortably past the
50MB/s design target.

```
tests/gen_big.sh 10000 > /tmp/big.v0
time ./v1 < /tmp/big.v0 > /dev/null
```

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
were found in the first place.

## Correctness stance

A wrong encoding that still runs is the worst thing an assembler can do,
so values that don't fit their target field are hard errors with a line
number, never silent truncation:

```
$ printf 'add rax, 0x123456789\n' | ./v1
v1: immediate out of range at line 1
```

The same applies to memory displacements wider than `disp32` and to
integer literals that overflow 64 bits. Every error path exits nonzero
with a distinct message on stderr — there are no assertion failures or
segfaults on malformed input.
