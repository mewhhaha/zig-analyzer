# Architecture and module boundaries

zig-analyzer separates transport, composition, and analysis policy. The useful
distinction is not file size by itself: thin modules wire stable interfaces
together, while thick modules own a cohesive proof or policy and test it close
to the implementation.

Dependencies point inward:

```text
entry points                 main.zig, zig_analyzer.zig
    |
transport                    lsp/        (the only code that speaks LSP)
    |
commands                     project/check.zig (CLI), project/check_cache.zig
    |
boundary adapters            actions/lsp_adapter.zig, compiler/ (protocol,
    |                        client, process, session, bootstrap)
    |
public facades/registries    analysis.zig, rules/registry.zig,
    |                        actions/registry.zig
    |
proof and policy engines     rules/<family>/*.zig, actions/{expression,language,
    |                        ownership,testing,project,rewrites,naming}.zig,
    |                        project/{module_sites,describe}.zig
    |
source-text models           syntax/ (tokens, scope, types, document,
                             declaration_summary, cursor, annotations,
                             text_edits, language_reference)
    |
shared domain types          rules/types.zig, rules/context.zig,
                             actions/context.zig, compiler/protocol.zig
```

`src/` is grouped by what a module may depend on:

| Directory | Membership criterion |
| --- | --- |
| `syntax/` | Reads source text only: no files, processes or protocol. Open documents, tokens, scopes, type sites, summaries, cursor queries, annotations and byte edits. |
| `compiler/` | Everything about the patched Zig compiler as a process: wire protocol, client, session, bootstrap, compile-unit discovery, `zig fmt`. |
| `project/` | Workspace-level facts shared by the CLI and the server: configuration, other files' declarations (`module_sites`, `describe`), imported deprecations, `check`. |
| `lsp/` | Speaks LSP: the `Server`, the compiler worker, diagnostics publishing, and one module per feature family. Nothing outside `lsp/` and `actions/lsp_adapter.zig` imports `lsp`. |
| `rules/`, `actions/` | Lint engines and rewrites; they emit findings and byte edits. |
| top level | Entry points (`main.zig`, `zig_analyzer.zig`), the `analysis.zig` facade, and leaf utilities (`uri.zig`, `filesystem.zig`). |

The `imports` contract in `zig-analyzer.json` denies `src/lsp` to the rule
engines, so a rule that reaches for transport fails `check`.

The compiler backend is another boundary. `compiler/protocol.zig` is the one
definition of the wire format (the patched compiler compiles the same file),
`compiler/client.zig` frames it behind a single request/response primitive,
`compiler/process.zig` owns the child process and its stderr, and
`compiler/session.zig` exposes domain queries (qualified-name lookup, resolved
shapes and values, type members) over a per-compile declarations cache.
Analysis consumes resolved shapes rather than compiler or protocol objects.
The CLI and the language server resolve configuration through one module,
`project/config.zig`, and convert file URIs through `uri.zig`.

Compile units come from the project's real build graph, not from reading
`build.zig`. `compiler/build_configuration.zig` runs the host
`zig build --print-configuration-path` (the configure phase only) and loads the
serialized `std.Build.Configuration`; `compiler/build_graph.zig` holds the
result: for each compile step under the `check` top-level step (else
`install`), its module graph (import name to module root source), target,
optimization mode and kind. A document is analyzed through the unit whose
module graph contains it: the unit rooted at the file, else a non-test unit,
else a test unit. The unit is lowered to `-M`/`--dep` arguments for the
patched compiler, so `build_options`, dependency and named modules resolve;
test units run as `test-obj`. `compiler/compile_units.zig` caches graphs per
build root (rediscovered when `build.zig`/`build.zig.zon` change). Module
sources produced by `Options` and `WriteFile` steps are materialized by
`compiler/generated_sources.zig` below `.zig-analyzer/generated`; modules
produced by any other step (running a program, translate-c) are reported once
as unavailable and analyzed without. The analyzer never executes a program the
project builds. Files in no unit, projects without a `build.zig`, and builds
that fail to configure are analyzed as a single file, with the failure
reported once.

The LSP keeps compiler work in `lsp/compiler_backend.zig`: a worker that owns
the compiler session and its own snapshot of every open document, queues one
job per document (a debounce of `default_debounce_ms` after the last edit), and
answers the foreground only through a narrow query API that never waits for a
running compile. A document's diagnostics are two layers, the lint layer
(syntax errors and rule findings, computed on the foreground from the current
version and the last known compiler shapes) and the compiler layer (compile
errors of exactly one version). `lsp/diagnostics.zig` holds the only code that
writes `publishDiagnostics`, merging the layers of one version, so a lint-only
republish keeps that version's compiler errors and a result for an outdated or
closed document is dropped. Tests drive the real worker and wait for it with
`CompilerBackend.waitIdle`; a server started with `Server.Options.syntax_only`
never starts a compiler.

`lsp/server.zig` is the `Server` struct, document synchronization and
diagnostics publishing; each feature request forwards to one module that takes
`lsp/services.zig` (documents, compiler worker facts, linter, resolver) rather
than the whole server: `hover`, `navigation`, `completion`, `code_actions`,
`rename`, `presentation` (symbols, semantic tokens, inlay hints, signature
help, code lens, call hierarchy, formatting). Those modules order strategies and
convert answers to LSP positions and shapes; what a name resolves to, what a
declaration looks like and which tokens carry hints are decided inward, in
`project/module_sites.zig`, `project/describe.zig` and `syntax/`.

Rename resolves member names by compiler identity. `syntax/symbol_query.zig`
reads one document and states each occurrence as a `Query` (enclosing named
containers, how to evaluate the receiver as names, calls and indexes, the name
to find) without knowing the compiler; `compiler/client.zig` sends a document's
queries in one `resolve_symbol` request and the patched backend
(`AnalysisSymbols.zig`) evaluates them against its resolved declarations,
returning each declaration's source name token or a status (`unresolved`,
`absent`, `generic`). `lsp/rename.zig` keeps the occurrences that resolve to
the declaration under the cursor, asks the other compile units that contain the
document (`BuildGraph.unitsContaining`, deduplicated by `analysisKey`) the same
questions and refuses on a provable difference, and falls back to syntax
scoping when no compiler answers. Compiler errors that merely say an import of
a module the build graph marked unavailable does not resolve are shown as
information naming the generating step (`compilerDiagnostics`).

Facts about other files (what an imported module exposes) are resolved by
`project/module_sites.zig` and handed to the rules as plain values
(`ModuleMembers`), so the language server and `check` report `unresolved-member`
through the same rule. `syntax/types.zig` holds the token-level type and
container walking those lookups share; `Document` builds one
`syntax/scope.zig` index per version, which rename, references, hover and the
lint rules all use.

## Thin modules

A thin module translates representations or composes independently testable
parts. It contains little policy and should be easy to replace:

- `analysis.zig` is the stable analysis facade.
- `rules/registry.zig` and `actions/registry.zig` establish deterministic
  composition order.
- `rules/configuration.zig` parses untrusted project configuration into rule
  domain types and reports precise boundary errors.
- `actions/lsp_adapter.zig` is the only action module that converts byte spans
  and URI edits into LSP workspace edits.
- `lsp/hover_markdown.zig` renders transport-neutral hover content as Markdown;
  `syntax/language_reference.zig` owns the Zig language catalog rather than
  presentation.
- `compiler/session.zig` isolates backend lifetime and stale-generation
  handling from language features.
- `lsp/server.zig` forwards each request to a feature module in `lsp/`.

Thin does not mean devoid of tests. Boundary behavior such as malformed JSON,
parent action-kind matching, stale generations, and UTF-16 conversion belongs
beside the adapter that guarantees it.

## Thick modules

A thick module owns facts that must stay consistent. It accepts explicit input,
returns domain values, and does not reach through transport or filesystem
globals:

- A syntax-local lint owns its matching, message, fix, and positive/negative
  tests in one `rules/<family>/<rule>.zig` module; families (`lifecycle`,
  `hazards`, `idioms`, `style`, `modernize`, `semantic`) group rules by what
  they prove, as `src/rules/README.md` defines.
- `lifecycle/allocation_lifecycle.zig` and `lifecycle/cleanup_lifecycle.zig`
  intentionally derive several diagnostics from one binding/lifetime model. Splitting each code into
  an independent traversal would duplicate identity rules and let findings
  disagree.
- `rules/summaries.zig` owns declared and inferred interprocedural ownership
  effects. Lifecycle rules query this one conservative source and treat
  recursion, ambiguity, and indirect calls as unresolved.
- `rules/semantic/containers.zig` owns the container facts (declared and compiler-resolved
  shapes) shared by member, switch-prong, struct-field and comptime-reflection
  diagnostics. It is a registry module like any other; new unrelated rules do
  not belong there. `rules/pipeline.zig` is the file-local driver and
  `rules/resources.zig` the one acquire/release table.
- Action family modules own the proof that a rewrite is safe. They return byte
  edits and never construct LSP values.
- `syntax/types.zig` follows explicit syntax facts such as function return
  types, imported dotted paths, and type aliases. Hover uses it as a fallback
  when no compiler expression type is available. `syntax/declaration_summary.zig`
  turns a declaration into the text, type summary and doc comment hover shows.

Large thick modules should be split along a proof boundary, not at an arbitrary
line count. A good extraction removes an input or dependency from the original
module and gives the new module a name based on the fact it owns.

## Composition contracts

The following rules keep feature work local:

1. Core rules and actions must not import `lsp`. Transport converts their byte
   spans at the edge.
2. Rules emit `Finding`; actions emit candidates containing complete edits.
   Neither publishes messages or mutates files.
3. Registries compose modules but do not reinterpret their findings or edits.
4. Configuration and suppression are applied uniformly. A rule must not read
   `zig-analyzer.json` itself.
5. Compiler facts cross the boundary as resolved shapes, compile-unit facts, or
   other small domain values, never raw protocol responses.
6. File-local analysis does not infer workspace reachability. Multi-file rules
   and actions use their explicit project boundaries.
7. Shared context modules contain syntax/span operations whose semantics must
   match within that subsystem. Similar helpers across rules and actions remain
   separate unless they represent the same invariant and must evolve together.

That last constraint avoids a broad syntax utility module becoming a coupling
hub. A little local duplication is cheaper than making every rule and action
depend on one unstable abstraction.

## Where a change belongs

| Change | Home |
| --- | --- |
| New independent diagnostic | `rules/catalog.zig` entry, `rules/<family>/<rule>.zig`, then `rules/registry.zig` |
| New diagnostic sharing an existing lifetime/type proof | The owning thick engine |
| New whole-project lint | `rules/project/<lint>.zig` over `ProjectRun`, listed in `rules/project.zig` |
| New selection rewrite | The closest `actions/<family>.zig`, then `actions/registry.zig` |
| New rewrite that repairs one finding | `actions/rewrites.zig` (`forFinding`) |
| New multi-file rewrite | `actions/project.zig` |
| New lint/profile setting | `rules/catalog.zig` and `rules/configuration.zig` |
| New compiler query | `compiler/protocol.zig`, client/session boundary, then a domain result |
| New language hover description | `syntax/language_reference.zig` |
| New hover Markdown layout | `lsp/hover_markdown.zig` |
| New declaration summary or cross-file description | `syntax/declaration_summary.zig`, `project/describe.zig` |
| New navigation strategy | `project/module_sites.zig` for the proof, `lsp/navigation.zig` for ordering and conversion |
| New LSP feature | A module in `lsp/` taking `Services`, one forwarding handler in `lsp/server.zig`, exchange tests in `tests/lsp/` |
| New CLI filesystem behavior | `project/check.zig` |

When a transport function starts proving Zig semantics, move that proof inward.
When a rule starts reading files or constructing protocol objects, move that
effect outward. When two diagnostics can disagree about the identity of the
same value, put them behind one thick proof engine.

## Maintenance checks

Before merging a structural change:

- inspect imports in both directions and reject new core-to-transport edges;
- keep the facade and registry APIs stable unless the domain model genuinely
  changed;
- add a boundary test when data changes representation;
- run `zig fmt --check`, `zig build check`, and `zig build test`; and
- run fixtures, examples, backend tests, and an editor exchange when the
  affected boundary reaches them.

See [EXTENDING.md](EXTENDING.md) for fork-oriented recipes and
`src/rules/README.md` and `src/actions/README.md` for the contracts within each
subsystem.
