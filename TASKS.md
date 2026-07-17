# zig-analyzer implementation tasks

Each task is independently reviewable. A task is complete only after every
acceptance criterion passes.

## ZA-001 — Repository and roadmap

Status: complete  
Depends on: none

Outcome: a Zig 0.16.0 project with a pinned LSP dependency, CLI contract, and
test entrypoint.

Acceptance:

- [x] `zig build`, `zig build check`, and `zig build test` pass.
- [x] `zig build run -- version` reports analyzer, Zig, and protocol versions.
- [x] `zig build run -- doctor` diagnoses the local Zig and backend state.

## ZA-002 — Reproducible compiler backend

Status: complete  
Depends on: ZA-001

Outcome: a verified Zig 0.16.0 source checkout is patched and built without
LLVM, with its source commit and patch hash recorded in a manifest.

Acceptance:

- [x] A clean-cache `zig build backend` produces the patched compiler.
- [x] A warm offline invocation reuses the verified compiler.
- [x] Version, patch, and protocol mismatches fail with the observed values.

## ZA-003 — Compiler analysis protocol

Status: complete  
Depends on: ZA-002

Outcome: compiler units accept in-memory overlays and expose generation-bound
diagnostics, semantic facts, symbols, types, members, and declarations.

Acceptance:

- [x] The handshake rejects incompatible versions and invalid tokens.
- [x] Unsaved overlays change compiler results without changing workspace files.
- [x] Stale generations and unavailable generic semantics return typed errors.

## ZA-004 — Workspace build driver

Status: in progress  
Depends on: ZA-003

Outcome: build graphs, generated modules, targets, options, and compile units
are discovered and kept alive for incremental analysis.

Acceptance:

- [x] A source file starts from the nearest build-declared root source when one
  unambiguously contains it, rather than becoming an isolated compile unit.
- [ ] `check` compile units are preferred, with `install` as the fallback.
- [ ] Required generation steps run without executing produced applications.
- [ ] Saved build-script changes reconfigure the affected compiler units.

## ZA-005 — Document store and syntax fallback

Status: complete  
Depends on: ZA-001

Outcome: current document versions provide byte/UTF-16 mapping, syntax trees,
scopes, declarations, imports, documentation, and cursor context.

Acceptance:

- [x] Full and incremental changes preserve exact source text and versions.
- [x] Syntax results remain current through incomplete and malformed edits.
- [x] Semantic responses from superseded generations are discarded.

## ZA-006 — LSP lifecycle and diagnostics

Status: in progress  
Depends on: ZA-004, ZA-005

Outcome: Helix can initialize, synchronize documents, receive diagnostics, and
shut down without leaking compiler processes.

Acceptance:

- [x] Lifecycle, cancellation, workspace folders, and document sync pass LSP tests.
- [ ] Parser diagnostics arrive immediately and compiler diagnostics are debounced.
- [ ] Backend failure preserves syntax service and performs one controlled restart.

## ZA-007 — Core semantic features

Status: in progress  
Depends on: ZA-006

Outcome: completion, hover, signature help, navigation, references, and rename
use compiler identities with explicit syntax fallback.

Acceptance:

- [ ] Comptime-generated members appear in completion and navigation.
- [x] Hover reports signature, documentation, type, and bounded comptime value.
- [ ] Rename refuses invalid, ambiguous, or multi-configuration identities.

## ZA-008 — Broad editor features

Status: in progress  
Depends on: ZA-007

Outcome: symbols, semantic tokens, inlay hints, and formatting complete the MVP.

Acceptance:

- [x] Document/workspace symbols and full/range semantic tokens pass LSP tests.
- [ ] Type and parameter hints are omitted when compile units disagree.
- [x] Formatting returns the exact Zig 0.16.0 `fmt --stdin` result.

## ZA-009 — Comptime regression corpus

Status: in progress  
Depends on: ZA-008

Outcome: observable compiler-protocol and LSP regressions cover generated types,
reflection, generic instantiations, imports, build options, and invalid edits.

Acceptance:

- [x] Valid fixtures compile independently with Zig 0.16.0.
- [ ] Unicode positions, rapid edits, deleted imports, and restarts are covered.
- [x] Tests assert protocol or LSP output rather than implementation internals.

## ZA-010 — Helix testbed and release gate

Status: complete  
Depends on: ZA-009

Outcome: this repository uses its local analyzer in Helix and documents the
complete setup and verification path.

Acceptance:

- [x] `hx --health zig` reports `zig-analyzer-local` after workspace trust.
- [x] The comptime fixture walkthrough exercises every advertised capability.
- [x] Clean bootstrap, formatting, tests, fixtures, and Helix smoke test pass.

## ZA-011 — Structured diagnostics and code actions

Status: complete  
Depends on: ZA-003, ZA-005, ZA-006

Outcome: stable native findings, configurable lints, compiler type shapes, and
complete workspace-edit actions cover common Zig diagnostics and refactors.

Acceptance:

- [x] Compiler protocol v4 distinguishes enums, tagged unions, and structs,
  including named comptime-generated types, while rejecting unsupported shapes.
- [x] Diagnostics merge stable native codes with parser/compiler output and
  retain compiler notes as related information.
- [x] Quick fixes, extraction/rewrite refactors, import organization, and safe
  fix-all are advertised and returned without a resolve round trip.
- [x] Configuration levels, per-rule overrides, and line, file, next-line, and
  scoped multi-rule suppressions report malformed or unknown values instead of
  silently ignoring them.

## ZA-012 — Lifetime diagnostics and opinionated formatting

Status: complete  
Depends on: ZA-011

Outcome: conservative resource/error/comptime findings and explicit safe
rewrites improve correctness while Zig remains the sole formatting authority.

Acceptance:

- [x] Allocation diagnostics cover late, mismatched, repeated, post-release,
  and overwritten ownership in mechanically proven scopes.
- [x] Standard resource cleanup, unsafe error assertions, lost error identity,
  undefined escape, and comptime reflection findings have clean counterexamples.
- [x] LSP formatting delegates directly to the pinned Zig formatter; safe
  rewrites and import organization remain separate source actions.
- [x] Default and style-enabled corpus scans complete deterministically without
  crashes; default new findings remain limited to high-confidence cases.

## ZA-013 — Idiomatic Zig analysis and comptime editor surface

Status: complete  
Depends on: ZA-011, ZA-012

Outcome: cumulative style-guide profiles and Zig-specific editor features make
resolved comptime code easier to read, navigate, and rewrite safely.

Acceptance:

- [x] Official, idiomatic, and strict profiles compose with tier and per-rule
  overrides, ESLint-style source suppressions, and precise configuration
  warnings.
- [x] Naming, documentation, optional/error flow, testing, pointer constness,
  finite error switches, imports, comptime markers, and result-location idioms
  have positive, negative, and action coverage.
- [x] Reflection string references participate in field rename, while API and
  file-name changes stay out of fix-all; formatting remains owned by Zig.
- [x] Resolved comptime type hover/code lenses, call hierarchy, format/import
  completion, semantic modifiers, and enum-value hints pass LSP tests.

## ZA-014 — Composable rule modules and Zig lifetime mistakes

Status: complete  
Depends on: ZA-013

Outcome: lint implementation lives behind a deterministic rule registry, and
common compiler-missed lifetime mistakes receive conservative diagnostics.

Acceptance:

- [x] `analysis.zig` remains a stable facade while rule types, execution
  context, registry, independent rules, and shared proof engines live under
  `src/rules`.
- [x] Profiles derive from rule metadata; tier and per-rule overrides still
  compose after profile defaults, and modular findings honor source
  suppressions.
- [x] Returning a slice backed by a local array and using a known container
  view after a potentially invalidating mutation are correctness warnings.
- [x] Late resource cleanup, redundant optional force-unwrapping,
  `orelse unreachable`, and byte-string test comparisons have positive,
  negative, and action coverage.

## ZA-015 — Escaping storage and project hygiene diagnostics

Status: complete  
Depends on: ZA-014

Outcome: compiler-missed owner/view lifetimes, exact testing idioms, and
directory-wide build hygiene receive conservative diagnostics.

Acceptance:

- [x] Local container/arena returns, invalidated element pointers and
  iterators, reassigned cleanup bindings, unchecked allocation sizes, and
  error-only resource cleanup have bounded positive and negative coverage.
- [x] Error collapsing, optional presence tests, testing expectations, unused
  captures, and manual sentinels compose through the idiomatic profile; only
  exact semantics-preserving rewrites enter fix-all.
- [x] The project checker reports normalized duplicate modules, repeated
  `@cImport`, orphaned test sources, and conflicting build-root options with
  configured levels and source locations.
- [x] Lifetime and idiomatic example files compile, expose the intended
  findings, and remain safe to run in the example suite.

## ZA-016 — Zig-native refactor actions

Status: complete  
Depends on: ZA-011, ZA-013, ZA-015

Outcome: compiler and syntax facts drive explicit Zig recovery, ownership,
comptime, reflection, build, C interop, and testing workspace edits.

Acceptance:

- [x] Error unions, optionals, tagged-union payloads, format strings, pointer
  casts, and allocation products expose context-specific actions.
- [x] Owned container returns, successful ownership transfer, exhaustive error
  handling, and uniform reflective dispatch preserve the proven Zig contract.
- [x] Compiler shapes support type materialization and reflected member
  generation without guessing unresolved shapes.
- [x] Open-workspace build imports, repeated C-import extraction, and generated
  test harnesses return complete edits; file creation is capability-gated.

## ZA-017 — Deferred-release and boundary diagnostics

Status: complete  
Depends on: ZA-014, ZA-015

Outcome: narrow ownership and integer-loop proofs catch additional
compiler-missed correctness failures, while locally weak index assertions remain
an idiomatic advisory when nonlocal invariants may already prove safety.

Acceptance:

- [x] Returning a directly acquired allocation or resource that normal `defer`
  releases reports the expired value and related cleanup location; `errdefer`
  ownership transfer stays clean.
- [x] An inclusive `<= sequence.len` assertion immediately followed by indexing
  the same sequence and path reports opt-in weak-bound guidance with an explicit
  local quick fix that remains outside fix-all.
- [x] Explicit unsigned countdown variables using `>= 0` and a `-= 1` loop
  update report the non-terminating condition and eventual underflow.
- [x] Each rule has positive, negative, and suppression coverage; corpus review
  demonstrated why weak-bound guidance cannot claim path-sensitive unsafety.

## ZA-018 — Syntax-bounded idiomatic rewrites

Status: complete
Depends on: ZA-014

Outcome: common verbose Zig expressions receive low-noise diagnostics and
mechanically safe rewrites in quick fixes and fix-all.

Acceptance:

- [x] Boolean-valued `if` expressions, empty `else` branches, and
  single-expression `defer` or `errdefer` blocks have independent rules.
- [x] Rewrites preserve comments by declining ambiguous forms and have
  positive, negative, suppression, and fix-all coverage.
- [x] The idiomatic example compiles and documents each editor-visible action.
