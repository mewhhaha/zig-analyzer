# Extending zig-analyzer

The extension seams are domain interfaces, not LSP request functions. A fork
should be able to add analysis or change presentation without teaching core
modules about JSON-RPC, UTF-16 positions, editor state, or the filesystem.

## Add a lint rule

For an independent file-local rule:

1. Add a `snake_case` member to `Rule` in `src/rules/types.zig`. Its public
   kebab-case code is derived automatically, so `missing_switch_prong` becomes
   `missing-switch-prong` everywhere configuration and diagnostics use it.
2. Add the rule to the appropriate tier in `Rule.tier`. New rules default to
   the opt-in style tier. Add it to `Rule.profile` only when a named profile
   should enable it.
3. Add a focused module under `src/rules/` with
   `pub fn run(context: RuleRun) !void`.
4. Add the module once to the ordered `rule_modules` tuple in
   `src/rules/registry.zig`.
5. Keep positive, negative, suppression, and fix tests in the rule module.
6. Add `<rule-code>.md` beside the rule modules and link it from
   `src/rules/RULES.md`; the test suite rejects missing documents, missing
   why/when sections, and duplicate or absent index links.

Use `RuleRun.emit` rather than appending a finding directly. It applies the
configured severity and all suppression forms consistently. A rule emits byte
spans and domain edits; it does not read configuration, publish diagnostics,
or mutate source files.

Do not create an independent traversal when the rule needs a fact already
owned by a thick proof engine. Allocation ownership belongs in
`allocation_lifecycle.zig`, cleanup ordering in `cleanup_lifecycle.zig`, and
container/scope facts in `semantic.zig`. Keeping one proof authoritative
prevents related diagnostics from disagreeing about the same binding.

Rules that need workspace reachability belong in `src/rules/project.zig` and
receive normalized paths and source text from the project scanner. They must
not infer project membership from one open document.

## Add a code action

Selection actions receive `ActionRun` and return complete byte edits. Add a
new action to the closest family in `src/actions/`: `expression.zig`,
`ownership.zig`, `language.zig`, or `testing.zig`. Add a new family only when
it owns a distinct proof boundary; add that family once to the ordered
`action_modules` tuple in `src/actions/registry.zig`.

Cross-file actions belong in `src/actions/project.zig`. The only code that
turns candidates into LSP workspace edits is `src/actions/lsp_adapter.zig`.
This keeps action tests independent of protocol representation and UTF-16
conversion.

An action should disappear when its safety preconditions cannot be proven.
Only independently semantics-preserving diagnostic fixes may opt into
fix-all. Scaffolding, ownership changes, generated declarations, and project
policy remain explicit actions.

## Change hover content or formatting

Hover has three separate owners:

- `src/language_hover.zig` is the catalog for Zig keywords, builtins,
  primitives, literals, operators, and punctuation. Change summaries,
  signatures, categories, or language-reference targets there.
- `src/hover.zig` defines transport-neutral hover content and the Markdown
  renderer. Change code fences, section ordering, or Markdown layout there.
  `MarkdownRenderer` is public, so an embedding application can supply its own
  renderer without changing analysis.
- `src/lsp_server.zig` resolves identifiers and adapts the rendered Markdown
  to the LSP response. It should select facts, not own presentation policy.

Both `hover` and `language_hover` are exported from `src/zig_analyzer.zig` for
embedders. Renderer tests assert Markdown directly; LSP tests should only cover
the protocol boundary and the selection of the right content.

## Extend compiler-backed analysis

Compiler changes cross a versioned boundary:

1. Define the request and response in `src/compiler_protocol.zig`.
2. Implement serialization in `src/compiler_client.zig` and lifecycle or
   stale-generation behavior in `src/compiler_session.zig`.
3. Convert the response to a small domain value before rules, actions, hover,
   or completion consume it.
4. Update the patched compiler sources and protocol compatibility tests.

Core analysis must not depend on raw JSON responses or compiler process state.
If the query cannot prove a fact, return unavailable and let the language
feature omit the diagnostic or action.

## Extend configuration or transport

`src/rules/configuration.zig` is the only parser for `zig-analyzer.json` and
suppression comments. Add project policy there, convert it to types in
`src/rules/types.zig`, and report malformed or unknown input at that boundary.
Rule modules consume the parsed policy and never inspect JSON themselves.

New LSP capabilities belong in `src/lsp_server.zig` only when they are thin
adapters. Put reusable semantics behind a transport-neutral module first, then
convert byte spans to protocol positions at the edge. CLI filesystem behavior
similarly belongs in `src/project_check.zig`, outside file-local analysis.

## Verification

Run the narrow test for the changed module while iterating, then run:

```sh
git ls-files -z '*.zig' '*.zon' | xargs -0 zig fmt --check
zig build check
zig build test
zig build fixtures
zig build examples
zig build -Doptimize=ReleaseFast
zig-out/bin/zig-analyzer check --no-cache .
```

Compiler protocol work also requires `zig build backend-test`. Changes to LSP
representation require an editor or recorded JSON-RPC exchange in addition to
unit tests.
