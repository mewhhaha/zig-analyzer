# zig-analyzer

A language server and linter for Zig. Instead of reimplementing Zig's
semantics, zig-analyzer builds a patched Zig 0.16.0 compiler and asks it what
each expression resolved to, falling back to syntax-based analysis when a
file does not compile.

- [Build and install from source](docs/installation.md)
- [Editor setup](docs/editors.md) for Helix and Neovim
- [Lint rules, configuration, and suppressions](docs/linting.md)
- [Versioning policy](docs/versioning.md)

## Why ask the compiler

Much of Zig's expressiveness lives in comptime: types are constructed in
`inline for` loops, declarations are selected with `@field`, and APIs are
gated behind comptime configuration. A language server that reasons from
syntax alone has to approximate those constructs, and the approximation
breaks down on ordinary code:

```zig
fn Pipeline(comptime stages: []const Stage) type {
    comptime var Current = Source;
    inline for (stages) |stage| {
        Current = switch (stage) {
            .buffered => Buffered(Current),
            .traced => Traced(Current),
        };
    }
    return Current;
}

const ActivePipeline = Pipeline(&.{ .buffered, .traced });

fn result() u32 {
    const pipeline: ActivePipeline = .{
        .inner = .{ .inner = .{ .value = 42 } },
    };
    return pipeline.trace();
}
```

This program compiles. Requesting completion after `pipeline.` produces
`Self`, `inner`, and `trace`.

Because zig-analyzer queries the compiler, it lists the members the resolved
type actually has, including the `trace` method the program calls two lines
later. The same mechanism resolves types selected through `@field` and APIs
gated behind comptime conditions, and hover shows compiler-evaluated values
for top-level constants rather than only their initializer text.

## Language server

zig-analyzer implements diagnostics, completion, hover, references, rename
(including declarations reached through reflection), call hierarchy, semantic
tokens, inlay hints, code actions, and formatting that matches `zig fmt`
byte for byte.

Configure your editor to run the executable with the `lsp` argument;
[docs/editors.md](docs/editors.md) has complete Helix and Neovim
configurations. This repository's own `.helix/languages.toml` is already set
up, so opening `examples/compiler/comptime_pipeline.zig` in Helix reproduces
the completion above.

Compiler updates run on a debounced background worker. The server answers from
the latest syntax immediately, then publishes compiler-enriched diagnostics
only if that result still matches the current document version. If the backend
hangs, a watchdog disconnects it without blocking foreground requests.

## Linter

The `check` command lints a project from the command line or CI:

```sh
zig-analyzer check .            # lint the project; exits nonzero on findings
zig-analyzer check --fix .      # apply only provably safe rewrites
zig-analyzer check --no-cache . # ignore cached results for unchanged files
```

The rules focus on valid Zig that is still wrong — patterns neither the
compiler nor a syntax-based server reports:

| Pattern | Rule |
| --- | --- |
| An allocation, then another `try`, no `errdefer` between | `missing-errdefer`, with a fix |
| `defer list.deinit();` then `return list.items;` | `returning-deinitialized-view` |
| Keeping `&list.items[i]` across an `append` | `invalidated-element-pointer` |
| `@memcpy` between overlapping slices of one buffer | `aliased-memcpy` |
| `while (i >= 0) : (i -= 1)` on an unsigned index | `unsigned-reverse-loop` |
| `count * size` passed straight to `alloc` | `allocation-size-overflow` |
| Byte-comparing a struct whose layout has padding | `padded-byte-compare` |
| `operation() catch {};` | `discarded-error` |

There are 133 rules with stable codes, organized into five named profiles,
with quick fixes wherever the rewrite is provable. Project contracts extend
the built-in analyses with your own import boundaries, resource pairs, and
must-use functions. Configuration lives in `zig-analyzer.json`, and findings
can be suppressed with source directives;
[docs/linting.md](docs/linting.md) documents all of it.

The engine runs without crashes over TigerBeetle (244 files), the complete
Zig standard library (550 files), and roughly 6,100 mangled fuzzing variants
of those sources — a run that surfaced two real bugs in the standard library.
Worst-case single-file analysis time on that corpus is 39 ms.

## Installation

Building requires Zig 0.16.0 exactly:

```sh
zig build -Doptimize=ReleaseFast
zig build backend                    # builds the patched compiler
zig-out/bin/zig-analyzer doctor      # verifies the setup
```

[docs/installation.md](docs/installation.md) covers the complete setup,
including how the patched backend is built and how to use it from other
projects.

## Versioning

Release versions track the supported Zig release: the base version names the
Zig version the analyzer targets, and a numeric suffix increments with each
zig-analyzer release, as in `0.16.0-1`. The suffix carries no compatibility
meaning. [docs/versioning.md](docs/versioning.md) states the full policy.

## Project status

zig-analyzer is an experiment, not a production language server. Most of its
code was written by LLM agents working against the repository's review
findings and test suite. The lint rules combine token-level file analysis,
conservative cross-file summaries, and compiler-backed project facts; they
stay opaque when a relationship cannot be proven. The compiler backend is
pinned to exactly Zig 0.16.0 and requires porting work for each new Zig
release. [TASKS.md](TASKS.md) records which planned work is complete.

The project's claim is narrow: querying the compiler produces better editor
answers than reimplementing it.

## Contributing and license

This repository does not accept pull requests; there is no maintenance
commitment behind it. It is MIT-licensed, so fork freely — the rules, the
example fixtures, and the backend protocol can all be reused without
permission. [ARCHITECTURE.md](ARCHITECTURE.md) documents the module
boundaries, [EXTENDING.md](EXTENDING.md) the extension seams, and
[`src/rules/README.md`](src/rules/README.md) the rule contract.
