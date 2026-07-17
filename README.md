# zig-analyzer

A Zig language server that asks a patched compiler what your program means
instead of guessing from syntax.

ZLS gives up on comptime. Not on exotic corner cases — on the point of the
language. Build a type in an `inline for`, pick a declaration with `@field`,
gate an API behind a comptime flag, and completion starts offering members of
types your program never instantiates. Hover says `anytype` and walks away.
Their docs call comptime analysis a work in progress; it's been one for years.

This project cheats instead: it builds a patched compiler, asks it what
everything resolved to, and falls back to syntax only when the file is too
broken to compile.

## Proof

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

This compiles. Ask for completion after `pipeline.`:

| Server | Candidates |
| --- | --- |
| zig-analyzer | `Self`, `inner`, `trace` |
| ZLS 0.16.0 | `value` |

ZLS never followed the loop, so the method the program calls two lines down
doesn't exist as far as it's concerned. Same story across the corpus: types
selected through `@field` (ZLS returns nothing), APIs gated behind comptime
conditions (ZLS offers the branch your build doesn't have). Everything is
pinned to Zig 0.16.0 and [ZLS 0.16.0 at
`4944862`](https://github.com/zigtools/zls/commit/494486203c3a48927f2383aa3d5ce5fca112186d),
kept as a regression corpus including the cases ZLS gets right, with a
[gallery](https://mewhhaha.github.io/zig-analyzer/) showing every cursor and
captured response. Reproduce it from
[`examples/compiler/comptime_pipeline.zig`](examples/compiler/comptime_pipeline.zig).

## Use it

Requires Zig 0.16.0 exactly:

```sh
zig build -Doptimize=ReleaseFast
zig build backend                    # builds the patched compiler
zig-out/bin/zig-analyzer doctor      # verifies the setup
```

Point your editor at `zig-out/bin/zig-analyzer` (`command = "...", args =
["lsp"]`). This repo's `.helix/languages.toml` already does; open
`examples/compiler/comptime_pipeline.zig` in Helix and try the completion
above. You get diagnostics, code actions, completion, hover, references,
reflection-aware rename, call hierarchy, semantic tokens, inlay hints, and
`zig fmt` formatting, byte-for-byte.

Or skip the editor and lint in CI:

```sh
zig-analyzer check .        # lint the project
zig-analyzer check --fix .  # apply only provably safe rewrites
```

The linter catches valid Zig that is still wrong — things neither the
compiler nor ZLS will ever mention:

| You wrote | You get |
| --- | --- |
| An allocation, then another `try`, no `errdefer` between | `missing-errdefer`, with a fix |
| `defer list.deinit();` then `return list.items;` | `returning-deinitialized-view` |
| Keeping `&list.items[i]` across an `append` | `invalidated-element-pointer` |
| `@memcpy` between overlapping slices of one buffer | `aliased-memcpy` |
| `while (i >= 0) : (i -= 1)` on an unsigned index | `unsigned-reverse-loop` |
| `count * size` passed straight to `alloc` | `allocation-size-overflow` |
| Byte-comparing a struct whose layout has padding | `padded-byte-compare` |
| `operation() catch {};` | `discarded-error` |

Around 80 rules, stable codes, three profiles, quick fixes wherever the
rewrite is provable, plus refactors ZLS doesn't attempt (`toOwnedSlice`
returns, `defer`→`errdefer` transfer, `inline else` collapses, `orelse
unreachable` → `.?`). Configure in `zig-analyzer.json`, suppress in source:

```json
{
  "lints": {
    "profile": "idiomatic",
    "rules": { "discarded-error": "warning" },
    "banned": [{ "path": "std.BoundedArray", "hint": "use stdx.BoundedArrayType" }]
  }
}
```

```zig
// zig-analyzer: disable-next-line missing-errdefer
const buffer = try allocator.alloc(u8, 4);
```

It holds up: the engine runs crash-free over TigerBeetle (244 files), the
entire Zig std (550 files), and ~6,100 mangled variants — and found two real
bugs in std doing it. Worst-case file analysis is 39 ms, down from 637 before
the accidentally-quadratic scans were found. A hung backend gets disconnected
by a watchdog and the server keeps answering from syntax.

## What this actually is

A vibecoded project. Most of it was written by LLM agents pointed at their own
review findings; the commit history says `ok`, `stuff`, and `uppiedates`. The
rules are token heuristics with a few hundred tests, not a semantic model.
The backend is pinned to exactly Zig 0.16.0 and will rot when Zig moves.
Analysis is per-file. Some TASKS.md items are unfinished because they are.

It is not the production comptime-aware Zig language server. It's a working
argument that asking the compiler beats reimplementing it.

## No contributions

Don't send PRs. Nobody here is going to maintain your feature.

Fork it and make it amazing. It's MIT — take the rules, the corpus harness,
the backend protocol, whatever survives contact with your standards, and build
the real one. [ARCHITECTURE.md](ARCHITECTURE.md) has the module boundaries,
[`src/rules/README.md`](src/rules/README.md) has the rule contract,
[TASKS.md](TASKS.md) says what's done. You don't need permission and you don't
need to credit anyone. Go.
