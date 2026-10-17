# zig-analyzer 0.17.0-3

This release adds 20 rules, reworks lint configuration, adds machine-readable
check reports and new editor features, and makes analysis several times
faster. It supports Zig 0.17.0 exactly and ships an x86_64 Linux archive with
the matching patched compiler.

## Rules and fixes

The catalog now contains 218 rules. New rules:

- Correctness: `assumed-concurrency`, `identity-operation`, `misplaced-try`,
  `mutated-range-bound`, `never-loop`, `removed-std-api`, `unawaited-async`,
  `unconsumed-delimiter`, `unflushed-writer`, `uninitialized-getorput-value`,
  `unreachable-code`, `unsigned-comparison-constant` and `unused-local`.
- Style and migration: `legacy-format-method`, `missing-deinit-poison`,
  `modernize-reify-type`, `pointless-discard`, `prefer-doctest`,
  `prefer-typed-io-parameter` and `unused-suppression`, which reports a source
  directive whose named rule never fired there.

The lifecycle checks follow containers by their declared type and report
use-after-release and double release for containers, arenas and owning structs,
including views and writers left over a freed buffer. Owned-field, `errdefer`
and container cleanup proofs cover more shapes.

False-positive classes found on the Zig standard library, the compiler,
ghostty, tigerbeetle and zls were removed from dozens of rules. Naming rules now
defer to the project's own conventions. The scope index reads functions with
braced return types, such as `error{A}!T` or `struct { ... }`, as functions.

Fix-all applies a rule's edits whole or not at all, repeats until nothing
changes, keeps the result formatted (a block it empties becomes `{}`), and
behaves the same in the CLI and the editor. Catalog examples are validated
through AstGen and a batch compile, and a wider rule fuzzer checks that fixes
round-trip.

## Configuration and command line

- `lints.correctness` and `lints.style` set the level of the rules already
  selected and never turn on others. `lints.profile` accepts an array of
  profiles.
- `overrides` reconfigures the files matching path patterns.
- `check --strict-config` stops on a configuration error.
- `check --write-baseline <file>` records the current findings, and
  `check --baseline <file>` then reports only the new ones.
- `check --format text|json|sarif|github` chooses the report format. The
  `github` format prints Actions annotations.
- `check --rule <code>` limits a check to the rules named.
- `check --fail-on <level>` sets the least severe finding that fails the check.
- `zig-analyzer explain <rule>` prints a rule's documentation, and
  `zig-analyzer explain` lists every rule.

[Linting](linting.md) documents all of it.

## Editor changes

- Diagnostics are pulled by editors that support `textDocument/diagnostic`.
- New features: document highlights, folding and selection ranges, links to
  imported files, "Run test" code lenses, and "caller frees" inlay hints after
  calls whose result the caller owns.
- Edits apply at once, and lint diagnostics follow once typing pauses.
- Files nested too deeply to parse safely are skipped instead of exhausting the
  stack.
- New quick fixes add overflow-aware arithmetic and generate `deinit`
  functions.

## Performance

Analysis uses a fixed worker pool and a shared cross-file index. Warm checks
reuse cached cross-file findings and build-root discovery. The allocation,
container, cleanup, ownership and cross-file engines are linear in file size,
and `tests/rule_scaling.zig` guards them. With the default configuration, in
runs alternating with 0.17.0-2:

- a full check of the 0.17.0 standard library is about six times faster;
- single large files such as LLVM `Builder.zig` and `Io/Threaded.zig` are
  about eight times faster;
- the compiler's 35.6k-line `Sema.zig` is about 30 times faster.

Peak memory on the standard library fell from about 900 MB to 350 MB.

Without a compiler backend, a check prints one notice and does not configure
any builds. With a backend, it configures the build roots in parallel.

## Upgrading

The compiler protocol stays at version 7. Install the analyzer and backend from
the same release together. For a source installation, rebuild both with
`zig build -Doptimize=fast` and `zig build backend`, then run
`zig-out/bin/zig-analyzer doctor` and restart your editor's language server.

Review `zig-analyzer.json`. A configuration that relied on
`"style": "warning"` to turn on style rules without a profile now enables
nothing. Name a profile in `lints.profile` or the rules in `lints.rules`. The
check cache format changed, so the first check after upgrading rebuilds it.
The `idiomatic` profile now includes `unused-suppression`, which may report
stale suppression directives.

## Validation

- More than 1,700 host tests, including rule examples, fix round trips, the
  rule fuzzer, scaling bounds, LSP exchanges and build graphs.
- 30 compiler-backed tests covering overlays, generated modules, concurrent
  backends, compiler identities and rename across compile units.
- Formatting, debug compilation, an optimized build, and an analyzer self-check
  with zero findings over 289 Zig source files.
- Corpus checks with every rule enabled on the standard library, the compiler,
  ghostty, tigerbeetle and zls, compared finding by finding against the
  previous build.
