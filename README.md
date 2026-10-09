# zig-analyzer

A language server and linter for Zig. Instead of reimplementing Zig's
semantics, zig-analyzer builds a patched Zig compiler and asks it what
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

zig-analyzer implements diagnostics, completion, hover, references, rename,
call hierarchy, semantic tokens, inlay hints, code actions, and formatting that
matches `zig fmt` byte for byte.

Renaming a field, method, enum case, or top-level declaration asks the compiler
which occurrences denote it: `x.name` through an alias, a pointer, a method
result, a `for` capture, or `@field(x, "name")`, and not the same spelling on
an unrelated type. If the file belongs to several compile units of your build
(an executable and its tests, or one program built with different options),
the rename is checked in each, and refused when the declaration differs between
them. Occurrences the compiler cannot resolve are left unchanged and reported.
Without a compiler, or for locals, rename uses syntax scoping; the editor log
says which mode ran. Rename waits for a compile in progress (at most 5 s) and
for each other compile unit it must start (at most 30 s, 16 units).

Configure your editor to run the executable with the `lsp` argument;
[docs/editors.md](docs/editors.md) has complete Helix and Neovim
configurations. This repository's own `.helix/languages.toml` is already set
up, so opening `examples/compiler/comptime_pipeline.zig` in Helix reproduces
the completion above.

Compiler updates run on a debounced background worker, one job per document.
The server answers from the latest syntax immediately, then publishes
compiler-enriched diagnostics only if that result still matches the current
document version; a republish of the same version keeps them. If the backend
hangs, a watchdog disconnects it without blocking foreground requests.
Ordinary source saves reuse the running incremental compiler and its analysis
state. Build configuration changes restart analysis to discover the current
source roots.

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
| Partially constructing an owning aggregate before another fallible step | `missing-errdefer` |
| `defer list.deinit();` then `return list.items;` | `returning-deinitialized-view` |
| Keeping `&list.items[i]` across an `append` | `invalidated-element-pointer` |
| Returning a view retained across `realloc` | `invalidated-container-view` |
| Clearing a container without releasing its proven owned element fields | `incomplete-owned-field-cleanup` |
| `@memcpy` between overlapping slices of one buffer | `aliased-memcpy` |
| `while (i >= 0) : (i -= 1)` on an unsigned index | `unsigned-reverse-loop` |
| `count * size` passed straight to `alloc` | `allocation-size-overflow` |
| Copying `file_reader.interface` into a new value | `copied-io-interface` |
| Calling `iterate()` after `openDir(..., .{})` | `directory-iteration-not-enabled` |
| Discarding the initialized-byte count from `readVec` | `discarded-read-count` |
| Passing undefined slice descriptors to `readVec` | `undefined-readvec-destination` |
| Byte-comparing a struct whose layout has padding | `padded-byte-compare` |
| `operation() catch {};` | `discarded-error` |

There are 198 rules with stable codes (see the [rule index](docs/rules/README.md)), organized into five named profiles,
with quick fixes wherever the rewrite is provable. Project contracts extend
the built-in analyses with your own import boundaries, resource pairs, and
must-use functions. Configuration lives in `zig-analyzer.json`, and findings
can be suppressed with source directives;
[docs/linting.md](docs/linting.md) documents all of it.

The [Zig 0.17.0 audit](docs/zig-0.17.0-lint-audit.md) reviews every existing
rule. The `modernize` profile covers removed syntax,
deprecated builtins and build APIs, changed bit casts, linkage values, and
container APIs. The idiomatic profile also offers `@divCeil` guidance.
Deprecation warnings follow standard-library and literal file imports, including
unsaved editor buffers. A new correctness check flags batch network sends whose
error result hides partial progress.

The engine runs without crashes over the complete Zig standard library, and the rule fuzz harness (`zig build fuzz-rules`)
feeds mutated and generated programs through every rule. Measured with the
optimized build (`check --no-cache`, 16 threads, wall clock, five runs each):
this repository (240 files) takes about 1.0 s, a copy of the 0.17.0 standard
library (563 files) about 5 s, and single files take 0.7 s for the 16.5k-line
LLVM `Builder.zig` and the 20k-line `Io/Threaded.zig`. Cost grows faster than
linearly with file size: the compiler's 35.6k-line `Sema.zig` takes about 4.5 s.

## Installation

Each release provides a relocatable x86_64 Linux archive containing both
zig-analyzer and its patched compiler backend. Verify the published SHA-256
checksum before installing it. Building from source requires exactly the Zig
release the version names (`0.17.0` for `0.17.0-2`):

```sh
zig build -Doptimize=fast
zig build backend                    # builds the patched compiler
zig-out/bin/zig-analyzer doctor      # verifies the setup
```

[docs/installation.md](docs/installation.md) covers the complete setup,
including how the patched backend is built and how to use it from other
projects. Each release has notes under [docs/](docs/README.md) for changes and
upgrade instructions.

## Versioning

Release versions track the supported Zig release: the base version names the
Zig version the analyzer targets, and a numeric suffix increments with each
zig-analyzer release, as in `0.17.0-2`. The suffix carries no compatibility
meaning. [docs/versioning.md](docs/versioning.md) states the full policy.

## Project status

zig-analyzer is pre-1.0 software with a narrow compatibility boundary: each
release supports exactly one Zig version. The lint rules combine token-level
file analysis, conservative cross-file summaries, and compiler-backed project
facts; they stay opaque when a relationship cannot be proven. The compiler
backend is pinned to exactly one Zig release and requires porting work for each
new one ([compiler/README.md](compiler/README.md)).

The project's claim is narrow: querying the compiler produces better editor
answers than reimplementing it.

## Contributing and license

The project is MIT-licensed; distributed third-party licenses are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Report security issues using
the private process in [SECURITY.md](SECURITY.md). See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute;
[ARCHITECTURE.md](ARCHITECTURE.md) documents the module boundaries,
[EXTENDING.md](EXTENDING.md) the extension seams, and
[`src/rules/README.md`](src/rules/README.md) the rule contract.
