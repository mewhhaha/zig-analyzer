# Developing zig-analyzer

This document covers contributor setup, the compiler backend, verification,
and manual editor testing. The user-facing motivation and behavior live in
[README.md](README.md).

## Build and verify

The project pins Zig 0.17.0 at commit
`7647adab80dd088f4de3610fd245915a912eb6ad`.

```sh
zig version # must print 0.17.0
git ls-files -z '*.zig' '*.zon' | xargs -0 zig fmt --check
zig build -Doptimize=fast
zig build backend
zig build test
zig build backend-test
zig build fixtures
zig build examples
zig build fuzz-rules
zig build rule-docs # regenerates docs/rules; `zig build test` fails when it is stale
zig-out/bin/zig-analyzer check --no-cache .
zig build run -- doctor
zig build run -- version
```

Tests are split by what they need. `zig build test` runs the unit tests next
to each module, the contract tests (`compiler/protocol_invariant.zig`), the
editor exchanges in `tests/lsp/` (one file per feature, sharing
`tests/lsp/support.zig`), the build-graph tests (`tests/build_graph.zig`, which
configure the small projects in `fixtures/projects/` with the host `zig`), the
rule examples and docs checks, fix round trips, the fixtures, the examples and the fuzz cases;
none of it needs the patched compiler.
`zig build backend-test` builds the backend and runs exactly the tests that do:
`tests/compiler_integration.zig` and `tests/lsp_compiler.zig`. Those fail when
the backend is missing rather than skip.

`zig build backend` clones the exact Zig source revision into `.zig-analyzer/`,
applies the narrow compiler patch, installs `src/compiler/protocol.zig` into
the checkout as `src/AnalysisProtocol.zig` (the analyzer and the backend compile
one definition of the wire format), builds without LLVM, and records the source
commit, a digest of the patch and protocol source, and the protocol version in
`zig-out/backend/zig-analyzer-backend.json`. Editing either input makes the
backend stale: the next `zig build backend` resets the checkout to the pinned
commit, reapplies the inputs, and rebuilds (about 15 minutes), and `doctor`
reports the mismatch until then. Bump `version` in `src/compiler/protocol.zig`
whenever the wire format changes (it is 7: `resolve_symbol` batches symbol
queries, see the comment above `ResolveSymbolsRequest`). The patch adds
`src/AnalysisSymbols.zig` beside `IncrementalDebugServer.zig`; to iterate on it
without the 15 minute rebuild, edit the checkout in `.zig-analyzer/zig-0.17.0`
and type-check with `zig build -Dno-lib -Denable-llvm=false
-Ddebug-extensions=true -Dno-bin` (about 30 s), then regenerate the patch with
`git add -N src/AnalysisSymbols.zig && git diff -- src/IncrementalDebugServer.zig
src/AnalysisSymbols.zig src/Zcu.zig src/Zcu/PerThread.zig src/main.zig`. Repeating the command with unchanged inputs
reuses the verified checkout and compiler caches.

At run time the analyzer starts the backend with `ZIG_ANALYZER_PORT=0`; the
backend binds a free loopback port and announces it on stderr, so concurrent
analyzers never collide. Backend stderr is kept (bounded) and logged when the
backend fails to start or exits uncleanly. Compiler caches live in
`.zig-analyzer/` under the project root: the directory that holds
`zig-analyzer.json`, else the workspace folder, else the file's directory.

On x86_64 Linux, keep a compiler running while editing to reuse Zig 0.17.0's
incremental analysis and receive build errors after each saved change:

```sh
zig build -fincremental --watch
# Or keep the test build running:
zig build test -fincremental --watch
```

Stop the watch process with Ctrl-C. A one-shot `zig build` still uses its normal
file caches; in-memory incremental state is reused by the running watch process.
See the [Zig 0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html#Incremental-Compilation)
for supported targets.

`TASKS.md` is the authoritative implementation ledger. A feature appearing in
the repository does not make an unchecked acceptance criterion complete.

## Architecture

zig-analyzer is an LSP server backed by an authenticated, versioned analysis
protocol added to the pinned Zig compiler. Syntax-backed answers remain
available while a document is incomplete; compiler-resolved shapes, members,
and top-level constant values augment them when the saved program can be
analyzed.

Editor diagnostics keep the patched compiler running with `-fincremental` and
reuse its analysis state across unsaved edits and ordinary source saves. Each
update also checks saved imports for changes. The compile unit that analyzes a
document comes from the build graph (`zig build --print-configuration-path`):
compile steps under the `check` step, else `install`, with their module
graphs passed to the compiler so `build_options` and dependencies resolve.
Keep every test binary a dependency of `check` (see `Tests` in `build.zig`):
that is how a file under test belongs to a unit. Saving `build.zig` or
`build.zig.zon` discovers the graph again and restarts analysis so a changed
build configuration can select the appropriate unit. Syntax diagnostics remain available while the
debounced compiler worker updates; compiler diagnostics publish only for the
current document version, and edits to several documents inside the debounce
all reach the compiler.

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
zig build -Doptimize=fast
hx --health zig
```

The repository-local `.helix/languages.toml` selects `zig-analyzer-local`, which
runs `zig-out/bin/zig-analyzer lsp`. On Helix versions with workspace trust
enabled, run `:workspace-trust` once before checking health. Use `:lsp-restart`
after rebuilding the analyzer.

The example sources are valid Zig programs. `zig build examples` compiles and
runs their tests. `examples/diagnostics/compiler_error.zig` and
`examples/diagnostics/code_actions.zig` are intentionally invalid and excluded
from that build so they can exercise diagnostics and actions.

`zig build fuzz-rules` runs the rule fuzz harness in `tests/rule_fuzz.zig`: it
generates clean-by-construction programs that must produce no default
findings, checks that formatting, comments, and consistent renames leave
findings unchanged, and feeds byte mutations and generated token soup through
every rule. The same tests run under `zig build test`; the continuous
`--fuzz` mode compiles and passes the seed tests, but Zig 0.17.0's continuous
fuzz driver then panics with `start index 1 is larger than end index 0`. The
same failure reproduces with a standalone no-op fuzz probe. The normal test
suite still runs the deterministic fuzz cases.

`tests/rule_fixes.zig` applies each catalog example's quick fixes and fix-all
edits, then checks that the result still parses, preserves formatting when
the input was formatted, and has no further fix-all edits for the same rule.
It also applies all enabled rules' fix-all edits together and checks that
their combined result parses. The example diagnostics and test-reachability
checks ensure the documented examples report their marked findings and every
source module with tests participates in the suite.

See [examples/README.md](examples/README.md) for exact completion, hover,
navigation, rename, diagnostic, and code-action cases.

## Comptime fixture walkthrough

Start Helix from the repository root so it loads the local language-server
configuration:

```sh
zig build backend-test
zig build -Doptimize=fast
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
zig-analyzer check [--fix] [--no-cache] <path>
zig-analyzer doctor
zig-analyzer backend bootstrap
zig-analyzer version
```

Project checks analyze files concurrently but buffer their output in sorted
path order. Unchanged-file findings are cached under
`.zig-cache/zig-analyzer/check-v1`; file contents, relative path, lint
configuration, and executable identity all participate in invalidation. Use
`--no-cache` for uncached profiling or cache troubleshooting.

`doctor` checks the host Zig version and every compatibility field in the
compiler-backend manifest. If the patch or protocol changes, rerun
`zig build backend`, followed by `zig build install` for an existing
installation. A backend using any protocol version other than the one printed
by `zig-analyzer version` is not compatible with the current analyzer.

## Publishing a release

Update `build.zig.zon` to the next version described in
[`docs/versioning.md`](docs/versioning.md), update the release version in the
installation documentation, and merge only after CI passes on `main`. Then
create and push an annotated tag with the same version:

```sh
git switch main
git pull --ff-only
git tag -a v0.17.0-1 -m "zig-analyzer 0.17.0-1"
git push origin v0.17.0-1
```

The Release workflow rejects a tag that differs from `build.zig.zon`, reruns
formatting and the complete test suite, builds the analyzer and patched
compiler from pinned inputs, exercises the assembled installation from a
temporary workspace, and publishes the archive with its SHA-256 checksum.
Never replace an existing release tag; increment the release suffix instead.
