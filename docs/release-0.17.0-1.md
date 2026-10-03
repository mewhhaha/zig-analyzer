# zig-analyzer 0.17.0-1

The first zig-analyzer release for Zig 0.17.0 updates the analyzer, its patched
compiler backend, and the pinned build dependencies. Compiler-backed analysis
requires the exact Zig 0.17.0 release. The compiler protocol remains version 5.

## Lint changes

All 190 existing rules were reviewed against the
[Zig 0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html)
and its standard library. All remain relevant. The
[complete audit](zig-0.17.0-lint-audit.md) records the disposition and evidence
for each rule.

Existing fixes and ownership checks now understand current search APIs,
optional `ArrayList.last()`, allocator printing and sentinel duplication,
public-only `@hasDecl`, and overlapping copies through `@memmove`. Power
simplifications preserve fallible integer-power behavior.

Nine new rules bring the catalog to 199. Eight are enabled by the opt-in
`modernize` profile:

- [`modernize-deprecated-builtin`](../src/rules/modernize-deprecated-builtin.md)
  covers enum conversions and deprecated builtin target constants.
- [`modernize-removed-syntax`](../src/rules/modernize-removed-syntax.md)
  covers removed C imports, array repetition, `void{}`, captured `errdefer`
  errors, and `i0`.
- [`modernize-build-api`](../src/rules/modernize-build-api.md)
  covers removed build argument access and deprecated C translation APIs.
- [`modernize-bitcast`](../src/rules/modernize-bitcast.md)
  requests review of array and vector bit casts whose semantics changed.
- [`modernize-extern-bitcast`](../src/rules/modernize-extern-bitcast.md)
  covers forbidden casts involving proven extern structs and unions.
- [`modernize-global-linkage`](../src/rules/modernize-global-linkage.md)
  covers removed `internal` and `link_once` values in linkage contexts.
- [`modernize-array-list-access`](../src/rules/modernize-array-list-access.md)
  migrates deprecated last-element accessors to `last()` or `last().?`.
- [`modernize-container-init`](../src/rules/modernize-container-init.md)
  migrates removed fixed-bitset and enum-set initializers to constant values.

The idiomatic profile adds
[`prefer-div-ceil`](../src/rules/prefer-div-ceil.md) for canonical unsigned
rounding arithmetic and proved standard-library ceiling-division calls.
Guidance carries no automatic edit because the builtin and the checked
standard-library function have different error-handling contracts.

Build migration guidance also covers removed `LazyPath.basename` and deprecated
Windows resource compilation, including proven module factories and compile
steps' `root_module` receivers.

Existing modernization rules also recognize the 0.17 standard-library moves,
reflection changes, allocator API replacements, and optimization mode names.
Migration guidance that requires a semantic choice carries no automatic edit.

## Editor and backend compatibility

The backend patch is rebased onto Zig's 0.17.0 source commit, with its digest
pinned in the build and recorded in the backend manifest. Bootstrap uses the
current build arguments and explicit compiler cache environment. The analyzer
uses the updated AST, reflection, tokenizer, and LSP dependency interfaces.
Reflective dispatch actions accept the new `field_names` representation.

Ordinary source saves keep the persistent incremental compiler session alive,
preserving analyzed declarations and dependencies for subsequent diagnostics.
Sending an unchanged overlay also reuses its source and generated analysis.
Updates still check saved imports; build script and package configuration saves
restart analysis to rediscover the build roots.

The Linux archive includes both the analyzer and patched backend. A separate
official Zig 0.17.0 installation supplies the standard library, as described in
the [installation guide](installation.md).

## Validation

- Host suite: all 30 build steps, including analyzer unit tests, nine rule
  fuzz tests, examples, protocol invariants, and CLI checks.
- Compiler-backed suite: ten integration cases, covering overlays, incremental
  updates, imported-file changes, and the backend protocol.
- Debug checks, the optimized build, formatting, and analyzer self-check.
- Linux archive smoke test: version, doctor, and compilation with the packaged
  backend from a temporary workspace.

Continuous `--fuzz` currently hits a Zig 0.17.0 driver panic after passing the
seed tests; the normal rule fuzz suite passes. The
[development guide](../DEVELOPING.md) records the reproduced limitation.

This branch prepares the `v0.17.0-1` release. Tagging and publication are handled
by the release workflow.
