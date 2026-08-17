# seed — archived bootstrap tool

`seed.asm` is the hand-verified, nasm-assembled program that bootstrapped
this project. It assembled the first `v1.v0` (the assembler written in its
own dialect, one level up in `../v1.v0`), and `v1` has assembled itself to
a byte-identical fixed point ever since — so nothing downstream depends on
`seed` anymore.

It's kept here, unmodified except for the bugs found while getting `v1` to
its fixed point (see the comments throughout `seed.asm` for what those
were), for two reasons:

- **The historical record.** Every step of the bootstrap — hand-encoded
  ELF header, the register-clobber bug that corrupted every `mov`'s
  register field, the `try_resolve_const` sentinel collision, the 32-bit
  truncation bug — is easier to understand by reading the file that had
  them than by reading about them after the fact.
- **A second, independent implementation to differential-test against.**
  `../tests/run_difftest.sh` checks both `v1` and `seed` against nasm;
  keeping seed buildable means that check still exercises two genuinely
  different encoders, not just one compared against itself.

To rebuild it: `nasm -f bin seed.asm -o seed && chmod +x seed`.

Do not grow `seed.asm` further — all dialect/perf work happens in
`../v1.v0` now, verified by having `v1` reassemble itself to a matching
fixed point after each change.
