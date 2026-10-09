# Developing zig-analyzer

This document covers setup, verification, the editor testbed and releases. The
user-facing motivation and behavior live in [README.md](README.md), the module
structure in [ARCHITECTURE.md](ARCHITECTURE.md), and the patched compiler in
[compiler/README.md](compiler/README.md).

## Setup

The project needs the Zig release named by `minimum_zig_version` in
`build.zig.zon` on `PATH` (`zig version` must print it exactly), plus Git for
the compiler backend. That manifest and `build.zig` are the only places the
Zig release and its pinned commit are written down.

```sh
zig build -Doptimize=fast
zig build backend                # builds the patched compiler; about 15 minutes cold
zig-out/bin/zig-analyzer doctor  # verifies the setup
```

## Verify

`zig build ci` is the one entry point; CI and the release workflow run exactly
it. In order, it runs

1. `zig fmt --check` over the Zig sources;
2. `zig build test`, which needs no patched compiler;
3. `zig build backend-test`, which builds the backend if it is missing and runs
   the tests that need it; and
4. the analyzer's own `check --no-cache .` over this repository, which must
   report no findings.

The release workflow additionally builds with `-Doptimize=fast` and runs
`zig-out/bin/zig-analyzer version` and `doctor`; do the same before tagging.
Narrower steps for iterating: `zig build check` (compile everything),
`zig build fixtures`, `zig build examples`, `zig build fuzz-rules`,
`zig build fix-check` and `zig build rule-docs` (regenerates `docs/rules`;
`zig build test` fails when they are stale).

Tests are split by what they need. `zig build test` runs the unit tests next
to each module, the contract tests (`compiler/protocol_invariant.zig`), the
editor exchanges in `tests/lsp/` (one file per feature, sharing
`tests/lsp/support.zig`), the build-graph tests (`tests/build_graph.zig`, which
configure the small projects in `fixtures/projects/` with the host `zig`), the
rule examples and docs checks, fix round trips, the fixtures, the examples and
the fuzz cases. `zig build backend-test` runs `tests/compiler_integration.zig`
and `tests/lsp_compiler.zig`, which fail when the backend is missing rather
than skip.

### Fix gates

A rule's fix may not make a program worse, so fixes pass three gates, each
stricter than the last (`tests/fuzz/round_trip.zig`, `tests/fuzz/compile_batch.zig`):

1. In process, for every fix and every fix-all of a program that parses: the
   result parses, lowers through `std.zig.AstGen` without an error the original
   did not report (errors are compared by message), is idempotent under a second
   fix-all, and stays `zig fmt`-clean when the input was.
2. Compiled, in one `zig test -fno-emit-bin` for the whole batch: programs and
   fix results are written to a temporary directory with every container member
   made `pub` and forced by a generated root, so Sema analyzes the function
   bodies. A fix result may not report a compile error that its original did not
   (non-lvalue `last().? = x`, an unused capture that AstGen misses, a type that
   no longer matches). Programs with AstGen errors or imports of missing files
   are left out, since either stops Sema for the whole compilation.
3. The same two gates on generated programs (`tests/rule_fuzz.zig`), which add
   idiom-breaking templates so the fixes see shapes the catalog examples lack.

`zig build fix-check` runs gates 1 and 2 over the catalog examples
(`tests/rule_fixes.zig`, a few seconds); `zig build test` includes it. When a
rule's fix breaks a gate, prefer fixing the rule (or declining the fix) over
weakening the example; an example that already fails to compile only exempts
the errors it has.

`tests/rule_fuzz.zig` is deterministic (fixed seeds) and takes about 8 s. It
checks that generated clean programs, which include zig-fmt-shaped variants
(trailing-comma headers, labeled blocks and switches, `inline else`, decl
literals), raise no finding under the default configuration or any lint profile,
that the same holds for generated multi-file projects run through the project
engine (the allocating templates are exempt from `allocation-after-init` only),
that findings survive formatting, comments and renames, and that no input crashes
a rule. Add a template there when a false positive is fixed.

## The compiler backend

`zig build backend` builds the patched compiler into `zig-out/backend`. Editing
`compiler/analysis.patch` or `src/compiler/protocol.zig` makes the backend
stale; the next `zig build backend` rebuilds it and `doctor` reports the
mismatch until then. [compiler/README.md](compiler/README.md) covers editing the
patch, the protocol version and porting to a new Zig release.

Compiler caches live in `.zig-analyzer/` under the project root: the directory
that holds `zig-analyzer.json`, else the workspace folder, else the file's
directory. Backend stderr is kept (bounded) and logged when the backend fails
to start or exits uncleanly.

On x86_64 Linux, keep a compiler running while editing to reuse Zig's
incremental analysis and receive build errors after each saved change:

```sh
zig build -fincremental --watch
# Or keep the test build running:
zig build test -fincremental --watch
```

Stop the watch process with Ctrl-C. See the
[Zig 0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html#Incremental-Compilation)
for supported targets.

## Editor testing

### Local Helix testbed

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
every rule. The same tests run under `zig build test`. The continuous `--fuzz`
mode compiles, but Zig 0.17.0's fuzz driver panics in it with `start index 1 is
larger than end index 0`, so rely on the deterministic runs.

`tests/rule_fixes.zig` applies each catalog example's quick fixes and fix-all
edits, then checks that the result still parses, preserves formatting when
the input was formatted, and has no further fix-all edits for the same rule.
It also applies all enabled rules' fix-all edits together and checks that
their combined result parses. The example diagnostics and test-reachability
checks ensure the documented examples report their marked findings and every
source module with tests participates in the suite.

See [examples/README.md](examples/README.md) for exact completion, hover,
navigation, rename, diagnostic, and code-action cases.

### Comptime fixture walkthrough

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

The version lives only in `build.zig.zon`; the Zig version follows from
`minimum_zig_version` (see [docs/versioning.md](docs/versioning.md)). To
release:

1. In one commit, set `.version` in `build.zig.zon` to the next version and add
   `docs/release-<version>.md` (indexed from `docs/README.md`). The release
   workflow publishes that file as the release notes.
2. Run the verification above, with the optimized build, and let CI pass on
   `main`.
3. Create and push an annotated tag with the same version:

```sh
git switch main
git pull --ff-only
git tag -a v<version> -m "zig-analyzer <version>"
git push origin v<version>
```

The Release workflow rejects a tag that differs from `build.zig.zon` or has no
`docs/release-<version>.md`, runs the CI workflow, builds the analyzer and
patched compiler, exercises the assembled installation from a temporary
workspace, and publishes the archive with its SHA-256 checksum and the notes
file. Never replace an existing release tag; increment the release suffix
instead.
