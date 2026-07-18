# Linting

`zig-analyzer check` analyzes a directory tree and reports lint findings; the
same rules produce diagnostics and quick fixes in the language server.

```sh
zig-analyzer check .            # exits nonzero while findings remain
zig-analyzer check --fix .      # applies only provably safe rewrites
zig-analyzer check --no-cache . # reanalyzes files with cached findings
```

Findings for unchanged files are cached between runs; `--no-cache` forces a
full reanalysis.

## Rules, tiers, and profiles

There are 133 rules. Each has a stable kebab-case code, such as
`missing-errdefer` or `discarded-error`, used consistently in configuration,
diagnostics, and suppression directives. The full index, with one document
per rule explaining why it exists and when it fires, is
[`src/rules/RULES.md`](../src/rules/RULES.md).

Every rule belongs to one of three tiers:

- **Semantic** diagnostics, such as unresolved calls and missing switch
  prongs, report code that cannot mean what it says. They are always on and
  cannot be configured.
- **Correctness** rules report valid-but-dangerous code and default to
  `warning`.
- **Style** rules are off by default and are enabled through a profile or
  per-rule configuration.

A profile enables a curated set of style rules:

- `official`, `idiomatic`, and `strict` progressively add style guidance.
- `modernize` targets migrations between pinned Zig releases.
- `disciplined` enables the bounded-loop, allocation, recursion, assertion,
  and function-size policies as an independent set.

## Configuration

Configuration is read from `zig-analyzer.json` in the directory being checked
(for the CLI) or the directory the editor starts the server in (for the
language server). Configuration errors are reported with the offending key
rather than silently ignored.

```json
{
  "check": {
    "exclude": ["zig-out", "vendor"]
  },
  "lints": {
    "profile": "idiomatic",
    "rules": {
      "discarded-error": "warning",
      "line-length": { "level": "warning", "max-columns": 100 },
      "todo-comment": { "level": "hint", "markers": ["TODO", "FIXME"] }
    },
    "banned": [
      { "path": "std.BoundedArray", "hint": "use stdx.BoundedArrayType" }
    ]
  }
}
```

- `check.exclude` lists relative paths that `zig-analyzer check` skips. Keep
  exclusions narrow; exact files are appropriate for intentionally invalid
  parser, formatter, or syntax-highlighting fixtures.
- `lints.profile` selects one of the five named profiles.
- `lints.correctness` and `lints.style` set one level for an entire tier.
- `lints.rules` sets individual rules to `off`, `hint`, `information`,
  `warning`, or `error`. A rule with settings of its own takes an object with
  a `level` and its specific options, as `line-length` and `todo-comment`
  show above.
- `lints.banned` reports any use of the listed dotted identifier paths,
  with an optional hint naming the preferred alternative.

## Project contracts

Contracts extend the built-in analyses with project-specific facts, so the
strongest proofs apply to your own APIs without heuristics:

```json
{
  "contracts": {
    "imports": [{ "from": "src/rules", "deny": ["src/lsp_server.zig"] }],
    "resources": [{ "acquire": "Db.open", "release": "Db.close" }],
    "must-use": ["Builder.finish"]
  }
}
```

- `imports` declares module boundaries: files under `from` may not import the
  denied paths.
- `resources` pairs an acquiring call with its releasing call, so the
  resource-lifecycle analysis reports acquisitions that are never released.
- `must-use` names functions whose return value must not be discarded.

## Cross-file analysis

The CLI builds conservative function summaries across direct calls.
Borrowing, release, escape, allocator provenance, and owned returns flow
across files; recursion, function pointers, ambiguous names, and unresolved
calls stay opaque rather than guessed at. Opt-in compiler-backed project
rules compare public type shapes across analyzed build roots and report
public declarations outside every successfully analyzed root's import graph.

## Suppressing findings

An intentional finding is suppressed with a source directive:

```zig
// zig-analyzer: disable-next-line missing-errdefer
const buffer = try allocator.alloc(u8, 4);
```

The available forms are:

```zig
// zig-analyzer: disable-file discarded-error

operation() catch {}; // zig-analyzer: disable-line discarded-error

// zig-analyzer: disable discarded-error, needless-defer-block
operation() catch {};
defer { close(); }
// zig-analyzer: enable discarded-error, needless-defer-block
```

`disable-next-line` applies only to the following line. `disable` remains in
effect until the matching `enable`, and `disable-file` must appear before any
code. Directives accept comma-separated rule codes; omit the codes or use
`all` to target every rule. Malformed directives and unknown rule codes are
reported instead of being ignored.

## Automatic fixes

`check --fix` and the fix-all source action in the editor apply only rewrites
that provably preserve semantics. Larger rewrites — converting a
`defer`-then-return sequence to `toOwnedSlice`, transferring cleanup from
`defer` to `errdefer`, collapsing `inline else`, replacing `orelse
unreachable` with `.?` — are offered as explicit code actions instead.
