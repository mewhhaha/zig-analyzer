# Comparing zig-analyzer

zig-analyzer overlaps two different tool categories. Language servers answer
editor requests such as completion and hover; linters inspect source for bugs,
risky patterns, and style problems. A useful comparison keeps those tracks
separate instead of treating every missing diagnostic as the same failure.

## Comparison tracks

### Language intelligence

Compare zig-analyzer with [ZLS](https://github.com/zigtools/zls) for:

- completion candidates and their resolved types;
- hover types, declarations, documentation, and comptime values;
- inlay hints, references, rename, and call hierarchy;
- compiler diagnostics produced after a saved document.

The checked-in [gallery](index.html) already captures this track. Its fixtures,
cursor positions, initialization options, save notifications, and timeout
behavior are documented in the [example guide](../examples/README.md). ZLS is
pinned to 0.16.0 at
[`4944862`](https://github.com/zigtools/zls/commit/494486203c3a48927f2383aa3d5ce5fca112186d).

### Lint diagnostics

Compare the `zig-analyzer check` command with dedicated linters for:

- ownership and resource lifecycle;
- stack escapes, bounds errors, and arithmetic hazards;
- error handling and discarded failures;
- naming, imports, API exposure, and modernization;
- documentation, complexity, and project policy.

ZLS remains a useful control because it can publish compiler and style
diagnostics, but it is not the primary competitor for this track.

## Tools

| Tool | Relevant analysis | Integration | Comparison role |
| --- | --- | --- | --- |
| zig-analyzer | Patched Zig compiler facts plus project summaries and lint rules | LSP and standalone CLI | Reference implementation |
| [ZLS](https://github.com/zigtools/zls) | Zig language server with syntax analysis and build-on-save compiler diagnostics | LSP | Language-intelligence baseline |
| [ZLint](https://github.com/DonIsaac/zlint) | Independent semantic analyzer; rules include returned stack references, suppressed errors, unsafe `undefined`, and unused declarations | Standalone CLI | General semantic-lint baseline |
| [ziglint](https://github.com/rockorager/ziglint) | Naming, imports, API exposure, error handling, casts, lifecycle conventions, and other idioms | Standalone CLI | Style and API-hygiene baseline |
| [zwanzig](https://github.com/forketyfork/zwanzig) | AST and ZIR analysis with path-sensitive CFG checkers for lifecycle, stack escapes, bounds, and divide-by-zero | Standalone CLI with text, JSON, and SARIF output | Correctness-analysis baseline |
| [Zlinter](https://github.com/KurtWagner/zlinter) | Configurable built-in and project-defined AST rules with experimental fixes | Integrated into `build.zig` | Extensibility and policy baseline |
| [Docent](https://github.com/jassielof/docent) | Public API traversal, documentation, complexity, and code-quality rules | CLI and library | Documentation and complexity baseline |

The ZLS comparison is captured today. The dedicated-linter rows define the
next adapters for the comparison harness; this page does not claim measured
results for them yet.

## Revisions for the first linter capture

The first reproducible run should use these revisions, selected on 2026-07-18:

| Tool | Revision |
| --- | --- |
| ZLint | [`fd0e42d`](https://github.com/DonIsaac/zlint/commit/fd0e42d866bbfa310810638fef5e829f32bd24f7) |
| ziglint | [`90dca75`](https://github.com/rockorager/ziglint/commit/90dca75f6301706f925c76c71aff58358758d923) |
| zwanzig | [`f1e8fa2`](https://github.com/forketyfork/zwanzig/commit/f1e8fa22a586f7406132335cef754b2cb9fd352d) |
| Zlinter 0.16.x | [`8b10b45`](https://github.com/KurtWagner/zlinter/commit/8b10b45d33c684be4f869baf95a37c282e9db750) |
| Docent | [`43d6580`](https://github.com/jassielof/docent/commit/43d65800c098cafe19a79617f9a12c6f232737fa) |

The capture output must also record zig-analyzer's commit, every executable's
reported version, the Zig executable used to build it, and the host platform.
A future update may move the pins, but a published gallery must never silently
follow a branch.

## Fair comparison rules

1. Run every tool on identical source bytes. Do not rewrite a fixture to suit
   one parser or naming convention.
2. Use the same Zig release where the tool supports it. Record unsupported
   versions as unsupported, not as a missed finding.
3. Check in the complete configuration supplied to each tool. Enable every
   rule relevant to the fixture and run a separate all-rules project scan.
4. Give language servers all relevant initialization options. Send save
   notifications when build diagnostics depend on them and wait for the same
   documented deadline.
5. Keep raw output alongside normalized results. Normalization may align file,
   span, severity, rule, and message fields, but must not discard extra
   diagnostics or related locations.
6. Report crashes, parse failures, timeouts, and unsupported checks explicitly.
   An empty result is not interchangeable with successful analysis.
7. Measure end-to-end wall time in a fresh process. If warm-cache performance
   is reported, label it separately and describe how the cache was primed.
8. Manually classify findings before publishing aggregate counts. A larger
   number is not better when it consists of false positives or unrelated style
   preferences.

## Fixture groups

Each fixture should state the behavior being tested and the tools with a
comparable rule. The initial groups should be:

| Group | Primary comparisons |
| --- | --- |
| Comptime-generated types and APIs | zig-analyzer, ZLS |
| Allocation leaks, double release, and use after release | zig-analyzer, zwanzig |
| Returned stack storage | zig-analyzer, ZLint, zwanzig |
| Discarded or swallowed errors | zig-analyzer, ZLint, ziglint, zwanzig, Zlinter |
| Naming, imports, and exposed private API | zig-analyzer, ziglint, Zlinter |
| Documentation and complexity | zig-analyzer, Docent, Zlinter |
| Compiler diagnostics | zig-analyzer, ZLS, `zig build` control |

A tool that has no corresponding rule should be shown as “not supported,” not
“no diagnostic.” This distinction keeps the gallery useful as an engineering
comparison rather than a scoreboard.

## Baseline controls

Every diagnostic capture should also run:

```sh
zig fmt --check fixture.zig
zig test fixture.zig
```

The formatter establishes whether a result is merely formatting policy. The
compiler establishes whether the fixture is invalid Zig, valid but dangerous,
or dependent on a language version. Compiler output should remain visible even
when another tool reports the same underlying problem.

## Publishing results

The existing capture script is [docs/tools/capture_comparisons.js](tools/capture_comparisons.js),
and the generated data is [docs/comparison-data.js](comparison-data.js). New
linter adapters should preserve the raw invocation, exit status, stdout,
stderr, elapsed time, tool revision, and normalized diagnostics. Generated
results belong in the gallery only after the fixture and its expected behavior
are covered by the repository test suite.
