# Architecture and module boundaries

zig-analyzer separates transport, composition, and analysis policy. The useful
distinction is not file size by itself: thin modules wire stable interfaces
together, while thick modules own a cohesive proof or policy and test it close
to the implementation.

Dependencies point inward:

```text
entry points                 main.zig, zig_analyzer.zig
    |
transport and commands       lsp_server.zig, project_check.zig
    |
boundary adapters            actions/lsp_adapter.zig, compiler_session.zig,
    |                        hover.zig
    |
public facades/registries    analysis.zig, rules/registry.zig,
    |                        actions/registry.zig
    |
proof and policy engines     rules/*.zig, actions/{expression,language,
                             ownership,testing,project}.zig, syntax_types.zig
    |
shared domain types          rules/types.zig, rules/context.zig,
                             actions/context.zig, compiler_protocol.zig
```

The compiler backend is another boundary. `compiler_client.zig` speaks the
versioned protocol, `compiler_session.zig` owns process and generation state,
and analysis consumes resolved shapes rather than compiler or JSON protocol
objects. The LSP keeps compiler work on a debounced worker with its own
document snapshots. Foreground requests use current syntax immediately;
compiler-enriched diagnostics publish only when the worker generation still
matches the latest document version.

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
- `hover.zig` renders transport-neutral hover content as Markdown;
  `language_hover.zig` owns the Zig language catalog rather than presentation.
- `compiler_session.zig` isolates backend lifetime and stale-generation
  handling from language features.

Thin does not mean devoid of tests. Boundary behavior such as malformed JSON,
parent action-kind matching, stale generations, and UTF-16 conversion belongs
beside the adapter that guarantees it.

## Thick modules

A thick module owns facts that must stay consistent. It accepts explicit input,
returns domain values, and does not reach through transport or filesystem
globals:

- A syntax-local lint owns its matching, message, fix, and positive/negative
  tests in one `rules/<rule>.zig` module.
- `allocation_lifecycle.zig` and `cleanup_lifecycle.zig` intentionally derive
  several diagnostics from one binding/lifetime model. Splitting each code into
  an independent traversal would duplicate identity rules and let findings
  disagree.
- `rules/summaries.zig` owns declared and inferred interprocedural ownership
  effects. Lifecycle rules query this one conservative source and treat
  recursion, ambiguity, and indirect calls as unresolved.
- `semantic.zig` owns container, scope, and type facts shared by diagnostics
  that cannot yet be expressed as independent `RuleRun` passes. New unrelated
  rules do not belong there.
- Action family modules own the proof that a rewrite is safe. They return byte
  edits and never construct LSP values.
- `syntax_types.zig` follows explicit syntax facts such as function return
  types, imported dotted paths, and type aliases. Hover uses it as a fallback
  when no compiler expression type is available.

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
| New independent diagnostic | `rules/<rule>.zig`, then `rules/registry.zig` |
| New diagnostic sharing an existing lifetime/type proof | The owning thick engine |
| New selection rewrite | The closest `actions/<family>.zig`, then `actions/registry.zig` |
| New multi-file rewrite | `actions/project.zig` |
| New lint/profile setting | `rules/types.zig` and `rules/configuration.zig` |
| New compiler query | `compiler_protocol.zig`, client/session boundary, then a domain result |
| New language hover description | `language_hover.zig` |
| New hover Markdown layout | `hover.zig` |
| New LSP representation | `lsp_server.zig` or a focused boundary adapter |
| New CLI filesystem behavior | `project_check.zig` |

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
