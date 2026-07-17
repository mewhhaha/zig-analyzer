# Developing zig-analyzer

This document covers contributor setup, the compiler backend, verification,
and manual editor testing. The user-facing motivation and behavior comparison
live in [README.md](README.md).

## Build and verify

The project pins Zig 0.16.0 at commit
`24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`.

```sh
zig version # must print 0.16.0
zig build
zig build backend
zig build test
zig build backend-test
zig build fixtures
zig build examples
zig build run -- doctor
zig build run -- version
```

`zig build backend` clones the exact Zig source revision into `.zig-analyzer/`,
checks the narrow compiler patch, builds without LLVM, and records the source
commit, patch hash, and protocol version in
`zig-out/backend/zig-analyzer-backend.json`. Repeating the command reuses the
verified checkout and compiler caches.

`TASKS.md` is the authoritative implementation ledger. A feature appearing in
the repository does not make an unchecked acceptance criterion complete.

## Architecture

zig-analyzer is an LSP server backed by an authenticated, versioned analysis
protocol added to the pinned Zig compiler. Syntax-backed answers remain
available while a document is incomplete; compiler-resolved shapes and members
augment them when the saved program can be analyzed.

The project separates thin transport/composition modules from thick proof and
policy modules. Core rules and actions return byte-span domain values and do
not depend on LSP types; focused adapters translate them at the boundary. See
[ARCHITECTURE.md](ARCHITECTURE.md) for dependency direction, module ownership,
and the maintenance checklist. Rule and action extension contracts live in
`src/rules/README.md` and `src/actions/README.md`.

Formatting has two profiles. `zig` passes the document directly to the pinned
`zig fmt --stdin`. `analyzer` gathers the same proven edits used by safe
fix-all, adds mixed-operator parentheses and optional import organization,
applies non-overlapping byte-span edits in memory, and then invokes `zig fmt`.
The LSP still returns one whole-document edit, so clients do not need special
support for the opinionated profile.

## Local Helix testbed

Build the analyzer before opening this repository in Helix:

```sh
zig build -Doptimize=ReleaseFast
hx --health zig
```

The repository-local `.helix/languages.toml` selects `zig-analyzer-local`, which
runs `zig-out/bin/zig-analyzer lsp`. On Helix versions with workspace trust
enabled, run `:workspace-trust` once before checking health. Use `:lsp-restart`
after rebuilding the analyzer.

The comparison sources are valid Zig programs. `zig build examples` compiles
and runs their tests. `examples/diagnostics/compiler_error.zig` and
`examples/diagnostics/code_actions.zig` are intentionally invalid and excluded
from that build so they can exercise diagnostics and actions.

See [examples/README.md](examples/README.md) for exact completion, hover,
navigation, rename, diagnostic, and code-action cases. To reproduce the ZLS
comparison, use ZLS 0.16.0 at commit
`494486203c3a48927f2383aa3d5ce5fca112186d`, change the Helix
`language-servers` entry temporarily, run `:lsp-restart`, and repeat the same
requests.

## Comptime fixture walkthrough

Start Helix from the repository root so it loads the local language-server
configuration:

```sh
zig build backend-test
zig build -Doptimize=ReleaseFast
hx fixtures/comptime/main.zig
```

Use `:lsp-restart` after rebuilding, then exercise the open fixture:

1. Insert `const preview = 42;`, confirm the `comptime_int` inlay hint appears,
   make the declaration temporarily incomplete to see a parser diagnostic, and
   undo both edits. This covers incremental synchronization, diagnostics,
   syntax fallback, semantic tokens, and inlay hints without saving the file.
2. Save after undoing the temporary edit, then request completion after `Mat3.`
   in `analyzerFixture`. `diagonal` and `trace` come from declarations observed
   by the patched compiler. Request signature help inside `Matrix(u32, 3, 3)`
   and hover `Matrix`.
3. Use go-to-definition and find-references on `Mat3`. Preview a rename of
   `Mat3`, cancel it, and inspect both document and workspace symbols.
4. Run `:format` and confirm the already-formatted fixture remains unchanged.

The automated protocol test performs the unsaved-overlay and generated-member
checks without changing the saved fixture. The in-memory LSP session covers
lifecycle, malformed incremental edits, symbols, semantic tokens, hints, and
shutdown; the walkthrough is the editor-facing smoke test.

## Commands and protocol compatibility

```text
zig-analyzer lsp
zig-analyzer check [--fix] <path>
zig-analyzer doctor
zig-analyzer backend bootstrap
zig-analyzer version
```

`doctor` checks the host Zig version and every compatibility field in the
compiler-backend manifest. If the patch or protocol changes, rerun
`zig build backend`, followed by `zig build install` for an existing
installation. Protocol v3 backends are not compatible with this release.
