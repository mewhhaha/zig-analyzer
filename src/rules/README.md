# Rule architecture

`analysis.zig` is the stable public facade. Rule implementation lives in this
directory and receives a tokenized document (tokens end with `.eof`), its syntax
tree, and its scope index through `RuleRun`; rules never read
files, publish LSP messages, or apply edits themselves.

## Layout

The root holds the machinery every rule shares: `types.zig`, `catalog.zig`,
`configuration.zig`, `context.zig` (`RuleRun`), `registry.zig`, `pipeline.zig`,
`project.zig`, the shared proof tables (`resources.zig`, `summaries.zig`,
`owned_call.zig`), `generated_source.zig`, `test_support.zig` and
`rule_docs.zig`. Rule modules live in a family directory chosen by what the
rule proves, never by its profile or tier:

| Directory | Membership criterion |
| --- | --- |
| `lifecycle/` | Proves the lifetime of an owned value: acquisition, release, transfer, invalidation, escape. |
| `hazards/` | Code that compiles but misbehaves: overflow, truncation, races, ignored I/O results, always-equal operands. |
| `idioms/` | Advice to rewrite into a clearer or cheaper equivalent (`prefer_*`, `redundant_*`, `needless_*`, `*_idioms`). |
| `style/` | Naming, layout, import, and discipline policies a project opts into; no behavior is wrong. |
| `modernize/` | Zig version migration: removed or deprecated APIs and syntax. |
| `semantic/` | Proofs over scope, container, and declaration facts instead of token patterns. |
| `project/` | Whole-project rules and the machinery they share (`ProjectRun`); see below. |

A module that bundles rules shares one proof between them, for example
`hazards/unsigned_arithmetic_guards.zig` (overflow before clamp, unchecked range
end), `lifecycle/child_process.zig`, `style/parameter_order.zig`,
`idioms/prefer_scalar_needle.zig` and `idioms/vector_literals.zig`. Unrelated
rules get separate modules even when they share a theme; helpers two modules
need move to `context.zig` (`RuleRun` methods) or `src/syntax/tokens.zig`.

## Adding a rule

Add an independent rule in these places:

1. Add its `snake_case` identifier to `types.zig`; the stable kebab-case code is
   derived from that name.
2. Add its entry to `catalog.zig`, the one table holding tier, profile,
   default level, settings, fix availability, summary, reference URL, and a
   minimal example. Everything else derives from it.
3. Add `<family>/<rule_name>.zig` (family per the table above) exporting `pub const rules = [_]Rule{...}` (exactly
   the rules it emits) and `pub fn run(context: RuleRun) !void`. Take allocation and
   output from the context: `context.allocator` and `context.emit`.
4. Add the module once to `registry.zig`'s ordered `rule_modules` tuple. The
   registry only runs a module when one of its `rules` is enabled, and a test
   requires every `Rule` to be owned by exactly one engine.
5. Keep positive, negative, and fix tests beside the rule. Tests call
   `test_support.findings` with the rule's `run`, which builds the same inputs
   as the pipeline driver; build configurations with
   `test_support.only(&.{.rule}, .information)`. `tests/rule_examples.zig`
   runs every catalog example through the pipeline and checks that the rule
   fires, offers the cataloged fixes, and honors `disable-file` and
   `disable-next-line`, so a per-rule suppression test is not needed.
6. Run `zig build rule-docs` and write the generated skeleton's two sections.

Token helpers shared by rules, actions, and documents (`tokenize`,
`matchingToken`, `statementEnd`, `topLevelComma`, `threeArguments`,
`containsComment`, ...) live in `src/syntax/tokens.zig`; `RuleRun` methods delegate to
them. Use `RuleRun.singleFix` for the common one-edit fix.

`RuleRun.emit` applies severity and source suppression uniformly. A rule owns
its messages and edits, and marks an edit as fix-all only when it is both
semantics-preserving and independent of project policy. The registry sorts the
combined result afterward, so modules do not depend on one another's order.

`configuration.zig` is the trust boundary for `zig-analyzer.json` and source
suppression directives. It converts JSON into the types in `types.zig`; rule
modules consume those types and never parse project configuration themselves.

Some findings share one proof and intentionally share an engine. For example,
`lifecycle/allocation_lifecycle.zig` recognizes an allocation once and derives missing,
late, mismatched, duplicate, post-release, and overwritten-ownership findings
from that same binding identity. Splitting those traversals by diagnostic code
would make their answers disagree. `semantic/containers.zig` similarly owns the six
rules that share resolved container facts (members, switch prongs, struct
fields, comptime reflection). New syntax-local rules should be separate
modules; extend a shared engine only when the new finding requires the same
proof.

`pipeline.zig` is the file-local driver: it parses and tokenizes once, builds
the scope index, runs `registry.run`, applies suppression directives once and
sorts the findings. `analysis.zig` re-exports it with the configuration and
finding types.

`resources.zig` is the single table of resource acquisition and release
knowledge (file and directory handles, threads, managed containers, allocator
methods). It merges the declared `contracts.resources` pairs with the built-in
ones, so every cleanup rule honours both.

A module may run helper passes that share its codes (`lifecycle/allocation_lifecycle.zig`
also runs the token-pattern ownership and late-cleanup passes), but the module
listed in the registry owns the rules. `project.zig` owns the rules only whole-
project analysis can report and lists in `refines` the file-local rules whose
findings it extends with cross-file summaries.

`summaries.zig` is the authoritative interprocedural ownership fact source.
Declared resource contracts and inferred direct-call effects both produce the
same borrowed, released, escaped, and owned-return summaries. Recursion,
ambiguous names, indirect calls, and unresolved calls stay opaque. Lifecycle
engines consume summaries; they do not independently reinterpret callees.

`project.zig` is the corresponding boundary for findings that require multiple
files. It receives normalized relative paths, complete source text, and small
compiler-fact domain values from the CLI scanner. File-local runners must not
infer build reachability or compare compile configurations from a single
document. The entry point owns an arena for its scratch work, so callers may
pass any allocator: `findings` returns `Finding` values (a file index plus a
`types.Finding` with level, fixes and related spans) copied to that allocator,
and `freeFindings` releases them.

`project/` splits the engine along proof boundaries. `project/run.zig` defines
`ProjectRun`, the project counterpart of `RuleRun` (files with tokens, the
configuration, compiler facts, a scratch allocator, and `report`/`emit`).
`project/ownership.zig` is the cross-file ownership engine: it builds the
summaries once, then runs `summary_checks.zig` (file-local lifecycle engines
re-run with callee summaries) and `owned_fields.zig` (cleanup of owned fields
and element sequences). The other modules are independent consistency lints
that share only `ProjectRun`: `import_graph.zig` (the import graph and the
rules that read it), `conventions.zig` and `majority.zig` (corpus-majority
naming, vocabulary and error-set conventions), `public_api.zig` (compiler-fact
rules over public declarations), `build_options.zig`,
`literal_boolean_argument.zig`, `allocation_after_init.zig` and
`recursive_call.zig`.

Each stable rule code has a page in `docs/rules/<rule-code>.md`. The index
`docs/rules/README.md` and the header and footer of every page are generated
from `catalog.zig` by `zig build rule-docs`; only the `## Why it matters` and
`## When it fires` sections are hand-written. A test fails when the committed
documents differ from the generated output, when a page is missing or documents
no rule, or when a template section is absent. Every diagnostic's
`codeDescription` links to its page.
