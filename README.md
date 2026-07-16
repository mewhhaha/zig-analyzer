# zig-analyzer

A Zig language server that asks a patched compiler what your program means
instead of guessing from syntax.

It exists because ZLS gives up on comptime. Not on exotic corner cases, on the
normal stuff. Build a type in an `inline for`, pick a declaration with
`@field`, gate an API behind a comptime flag, and completion starts offering
members of types your program never instantiates. Hover says `anytype` and
walks away. The ZLS docs are upfront that comptime analysis is a work in
progress, and that's a fair label, but it's been a work in progress for years
and metaprogramming is the entire point of the language. Tooling should get
more useful as the type logic gets harder. It currently gets less.

So this project cheats. It builds a patched Zig compiler, asks it what
everything resolved to, and only falls back to syntax when the file is too
broken to compile.

## Where ZLS gives up

A pipeline whose final type is assembled at comptime:

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

This compiles and runs. Put the cursor after `pipeline.` and ask for
completion:

| Server | Completion candidates |
| --- | --- |
| zig-analyzer | `Self`, `inner`, `trace` |
| ZLS 0.16.0 | `value` |

ZLS answers with a member of the starting `Source` type. It never followed the
loop, so `trace`, the method the program calls two lines down, isn't offered
at all. zig-analyzer lists the members of `Traced(Buffered(Source))` because
the compiler told it what `ActivePipeline` is. You can reproduce this from
[`examples/compiler/comptime_pipeline.zig`](examples/compiler/comptime_pipeline.zig).

More of the same:

| Comptime operation | zig-analyzer | ZLS 0.16.0 |
| --- | --- | --- |
| Compose a type through `inline for` | Completes the final `trace` method | Completes the initial type, misses `trace` |
| Select a type through `@field` | Completes `verify` | Returns nothing |
| Gate an API behind a comptime condition | Offers the active `recordMetric`, excludes the disabled branch | Offers both, including the one your build doesn't have |
| Reflected, parsed, recursively wrapped types | Resolves the generated members | Also resolves these |

The comparison is pinned to Zig 0.16.0, compiler protocol v4, and
[ZLS 0.16.0 at `4944862`](https://github.com/zigtools/zls/commit/494486203c3a48927f2383aa3d5ce5fca112186d),
and it's kept as a regression corpus, including the cases where ZLS does fine.
The [comparison gallery](https://mewhhaha.github.io/zig-analyzer/) has the
exact code, cursor position, and captured response for each one.

ZLS is otherwise a solid general-purpose server. Workspace symbols, cross-file
references, build-aware imports, years of editor integration work. None of
that is in dispute. The dispute is what happens once the answer depends on
actually evaluating the program, because a list of syntactically possible
types and the type your program has are not the same thing.

## The linter

The compiler only rejects invalid programs. There's a lot of valid Zig that is
still wrong, and neither the compiler nor ZLS will say anything about it:

| You wrote | You get |
| --- | --- |
| An allocation with no visible release or ownership transfer | `unreleased-allocation` |
| An allocation, then another `try`, no `errdefer` between | `missing-errdefer`, with a fix that inserts one |
| `defer list.deinit();` followed by `return list.items;` | `returning-deinitialized-view` |
| Returning `local_array[0..]` | `returning-local-slice` |
| Keeping `&list.items[i]` across an `append` | `invalidated-element-pointer` |
| Mutating a map while its iterator drives the loop | `iterator-invalidated-during-loop` |
| `@memcpy` between overlapping slices of one buffer | `aliased-memcpy` |
| Double free, use-after-free, overwritten owner | `double-release`, `use-after-release`, `overwritten-owning-value` |
| `while (i >= 0) : (i -= 1)` on an unsigned index | `unsigned-reverse-loop` |
| `count * size` passed straight to `alloc` | `allocation-size-overflow` |
| Byte-comparing a struct whose layout has padding | `padded-byte-compare` |
| `usize` field in a `packed` struct | `usize-in-packed-struct` |
| `operation() catch {};` | `discarded-error` |
| Returning memory owned by a local arena | `returning-arena-allocation` |

That's a sample. There are around 80 rules with stable codes, severity levels,
three cumulative profiles (`official`, `idiomatic`, `strict`), a configurable
banned-identifier list, and ESLint-style suppressions. Quick fixes exist
wherever the rewrite can be proven mechanically, and there are Zig-specific
refactors ZLS doesn't attempt: exhaustive error switches, `toOwnedSlice`
returns, `defer` to `errdefer` ownership transfer, tagged-union payload
switches, `inline else` collapses, splitting `assert(a and b)`, rewriting
`orelse unreachable` to `.?`.

It also runs headless:

```sh
zig-analyzer check .        # lint the project
zig-analyzer check --fix .  # apply only the provably safe rewrites
```

## Stability

Things that are tested rather than aspirational:

The rule engine runs crash-free over TigerBeetle (244 files) and the entire
Zig standard library (550 files), plus about 6,100 truncated and mangled
variants of those files. The false positives those runs exposed were fixed
with regression tests, and the sweep found two real bugs in std along the way
(a missing switch prong in `Build/Step.zig`, an error-path leak in
`Build/Fuzz.zig`).

Analysis is fast enough to run on every keystroke. The worst file in the std
corpus, `c.zig` at 371 KB, takes about 39 ms. It took 637 ms before the
accidentally-quadratic scans were found, which should tell you something about
how this codebase was written.

A hung compiler backend gets disconnected by a watchdog and the server keeps
serving syntax-level answers, with one controlled restart. Malformed protocol
frames, half-typed multi-byte characters, edits arriving mid-analysis, and
diagnostics computed against text that has since changed are all clamped and
covered by tests.

## What this actually is

This is a vibecoded project. Most of it was written by LLM agents pointed at
their own review findings over a handful of sittings. The commit history says
`ok`, `stuff`, and `uppiedates`.

You should know what that means in practice. The lint rules are token-stream
heuristics with a few hundred tests, not a semantic model. They were tuned
against two large corpora until the false positives stopped, and they stay
silent rather than guess, but `semantic.zig` is 3,600 lines of pattern
matching and nobody should pretend otherwise. The backend needs a patched
compiler pinned to exactly Zig 0.16.0 and will rot when Zig moves. Analysis is
per-file, so there is no whole-program lifetime story. Some TASKS.md items are
marked incomplete because they are.

So: not the production comptime-aware Zig language server, but a working
argument that asking the compiler beats reimplementing it. If someone wants to
build the real one, this is a usable starting point and it's MIT licensed.
Fork it, rip out whatever you don't like, keep the rules if they're useful.
[ARCHITECTURE.md](ARCHITECTURE.md) has the module boundaries,
[EXTENDING.md](EXTENDING.md) has fork-oriented recipes, and
[`src/rules/README.md`](src/rules/README.md) has the rule contract. The
[rule reference](src/rules/RULES.md) explains what every diagnostic reports,
why it matters, and when it is appropriate. You don't need to ask permission.

## Try it

Requires Zig 0.16.0 exactly:

```sh
zig version   # must print 0.16.0
zig build
zig build backend           # builds the patched compiler
zig-out/bin/zig-analyzer doctor
```

The repo's own `.helix/languages.toml` points at the local build:

```sh
hx examples/compiler/comptime_pipeline.zig
```

Run `:workspace-trust` once, then `:lsp-restart`, put the cursor after
`pipeline.` and request completion.

Severities live in `zig-analyzer.json`:

```json
{
  "lints": {
    "profile": "idiomatic",
    "correctness": "warning",
    "rules": { "discarded-error": "warning" },
    "banned": [
      { "path": "std.BoundedArray", "hint": "use stdx.BoundedArrayType" }
    ]
  }
}
```

Suppressions go in source. Unknown rules and malformed directives produce
warnings rather than being silently ignored:

```zig
// zig-analyzer: disable-next-line missing-errdefer
const buffer = try allocator.alloc(u8, 4);
```

The LSP surface covers diagnostics, code actions, completion, hover, signature
help, definition, references, reflection-aware rename, call hierarchy,
symbols, semantic tokens, inlay hints, code lenses, and formatting, which is
delegated byte-for-byte to `zig fmt`. Hover and a
`zig-analyzer.peekResolvedType` code lens expose compiler-resolved comptime
types directly.

[DEVELOPING.md](DEVELOPING.md) covers the backend bootstrap and verification
suite, [examples/README.md](examples/README.md) lists every comparison cursor,
and [TASKS.md](TASKS.md) tracks what's done and what isn't.
