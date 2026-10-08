# Extending zig-analyzer

The extension seams are domain interfaces, not LSP request functions. A fork
should be able to add analysis or change presentation without teaching core
modules about JSON-RPC, UTF-16 positions, editor state, or the filesystem.

## Add a lint rule

For an independent file-local rule:

1. Add a `snake_case` member to `Rule` in `src/rules/types.zig`. Its public
   kebab-case code is derived automatically, so `missing_switch_prong` becomes
   `missing-switch-prong` everywhere configuration and diagnostics use it.
2. Add one entry to the table in `src/rules/catalog.zig`: tier, minimum
   profile (only when a named profile should enable it), settings, fix
   availability, a one-sentence summary, and a minimal `example` that triggers
   the rule (or the reason it has none). Tier, profile, defaults, settings
   parsing, editor links, and the rule documents all derive from that entry.
3. Add a focused module under the family directory of `src/rules/` that
   matches what the rule proves (`lifecycle/`, `hazards/`, `idioms/`, `style/`,
   `modernize/`, or `semantic/`; the criteria are in `src/rules/README.md`) with
   `pub const rules = [_]Rule{...}`, listing exactly the rules it emits, and
   `pub fn run(context: RuleRun) !void`. Every rule is owned by exactly one
   module; a test enforces it.
4. Add the module once to the ordered `rule_modules` tuple in
   `src/rules/registry.zig`. The registry skips a module whose rules are all
   off.
5. Keep positive, negative, and fix tests in the rule module, using
   `src/rules/test_support.zig` (`findings`, `only`, `expectRules`).
   `tests/rule_examples.zig` already checks every catalog example for firing,
   fix availability, and both suppression directives, so rules do not need a
   suppression test of their own.
6. Run `zig build rule-docs`. It creates `docs/rules/<rule-code>.md` with a
   generated header and footer and the index; replace the placeholder body with
   the `## Why it matters` and `## When it fires` sections. The test suite
   rejects documents that differ from the generated parts, lack those sections,
   or document no rule.

Use `RuleRun.emit` rather than appending a finding directly. It applies the
configured severity and all suppression forms consistently. A rule emits byte
spans and domain edits; it does not read configuration, publish diagnostics,
or mutate source files.

Do not create an independent traversal when the rule needs a fact already
owned by a thick proof engine. Allocation ownership belongs in
`lifecycle/allocation_lifecycle.zig`, cleanup ordering in
`lifecycle/cleanup_lifecycle.zig`, and container facts in
`semantic/containers.zig`. Which calls acquire a resource and
which release it is answered only by `rules/resources.zig`. Keeping one proof authoritative
prevents related diagnostics from disagreeing about the same binding.

Rules that need workspace reachability belong in `src/rules/project/` (driven
by `src/rules/project.zig`; a new lint takes a `ProjectRun` and calls
`run.report`) and receive normalized paths and source text from the project
scanner. They must
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

- `src/syntax/language_reference.zig` is the catalog for Zig keywords, builtins,
  primitives, literals, operators, and punctuation. Change summaries,
  signatures, categories, or language-reference targets there.
- `src/lsp/hover_markdown.zig` defines transport-neutral hover content and the
  Markdown renderer. Change code fences, section ordering, or Markdown layout there.
  `MarkdownRenderer` is public, so an embedding application can supply its own
  renderer without changing analysis.
- `src/lsp/hover.zig` orders the compiler's facts and the syntax-side
  descriptions (`src/syntax/declaration_summary.zig`,
  `src/project/describe.zig`) and adapts the rendered Markdown to the LSP
  response. It should select facts, not own presentation policy.

`zig_analyzer.lsp.hover_markdown` and `zig_analyzer.syntax.language_reference`
are exported from `src/zig_analyzer.zig` for embedders. Renderer tests assert Markdown directly; LSP tests should only cover
the protocol boundary and the selection of the right content.

## Extend compiler-backed analysis

Compiler changes cross a versioned boundary:

1. Define the request and response in `src/compiler/protocol.zig`. The backend
   compiles the same file, so keep it free of analyzer imports and bump
   `version` when the wire format changes.
2. Add a typed method to `src/compiler/client.zig` built on `roundTrip`, and a
   domain query (with any lookup or caching) in `src/compiler/session.zig`.
3. Convert the response to a small domain value before rules, actions, hover,
   or completion consume it.
4. Update the patch in `compiler/` to handle the new tag;
   `compiler/protocol_invariant.zig` checks that it only names declarations the
   protocol file defines. Regenerate the patch from the checkout in
   `.zig-analyzer/` (`git diff HEAD` of the files it touches, without
   `src/AnalysisProtocol.zig`) and run `zig build backend`.

Core analysis must not depend on raw JSON responses or compiler process state.
If the query cannot prove a fact, return unavailable and let the language
feature omit the diagnostic or action.

## Extend configuration or transport

`src/rules/configuration.zig` is the only parser for `zig-analyzer.json` and
suppression comments. Add project policy there, convert it to types in
`src/rules/types.zig`, and report malformed or unknown input at that boundary.
Rule modules consume the parsed policy and never inspect JSON themselves.

New LSP capabilities are a module in `src/lsp/` that takes `Services`
(`src/lsp/services.zig`) plus one forwarding handler in `src/lsp/server.zig`.
Put reusable semantics behind a transport-neutral module first (`src/syntax/`
for source text, `src/project/` for other files), then convert byte spans to
protocol positions at the edge. Exchange tests go in `tests/lsp/`, grouped by
feature, and drive the public server API through `tests/lsp/support.zig`; tests
that need the patched compiler go in `tests/lsp_compiler.zig`. CLI filesystem
behavior similarly belongs in `src/project/check.zig`, outside file-local
analysis.

## Verification

Run the narrow test for the changed module while iterating, then run:

```sh
git ls-files -z '*.zig' '*.zon' | xargs -0 zig fmt --check
zig build check
zig build test
zig build fixtures
zig build examples
zig build -Doptimize=fast
zig-out/bin/zig-analyzer check --no-cache .
```

Compiler protocol work also requires `zig build backend-test`. Changes to LSP
representation require an editor or recorded JSON-RPC exchange in addition to
unit tests.
