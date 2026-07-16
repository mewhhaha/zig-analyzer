# zig-analyzer

**A compiler-backed Zig language server that doesn't fall over the moment you
write `comptime`.**

Let's be honest about the state of things. Zig's entire pitch is that the
language *is* the metaprogramming — you build types in `inline for` loops,
select APIs with reflection, and assemble your program at compile time. And the
moment you actually do that, ZLS shrugs. Completion offers you members of a
type your program never uses. Hover tells you something is `anytype` — thanks.
Go-to-definition takes you somewhere that stopped being relevant three
`comptime` branches ago.

This is not a niche edge case. It is the *point of the language*. Editor
tooling should get more useful as the type logic gets harder, not evaporate
exactly when you need it. ZLS is a capable server for conventional-looking
code, and its own docs are upfront that comptime analysis is a work in
progress — fine. But "work in progress" has been the status quo for years, and
some of us write pipelines.

So this project cheats: it asks a **patched Zig compiler** what the program
actually resolved to, instead of re-deriving Zig semantics from syntax and
hope. Syntax-based answers still cover half-typed files; compiler facts take
over when the code stops looking like a conventional language.

## Where ZLS gives up and this doesn't

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

Valid program. Both servers stay running. Ask for completion at `pipeline.`:

| Server | Completion candidates |
| --- | --- |
| zig-analyzer | `Self`, `inner`, `trace` |
| ZLS 0.16.0 | `value` |

ZLS offers a member of the *initial* `Source` type. It never follows the loop,
so the method the program actually calls — the one on the line below the
cursor — is missing. zig-analyzer asks the compiler for the resolved container
and lists what's really there. Reproduce it yourself:
[`examples/compiler/comptime_pipeline.zig`](examples/compiler/comptime_pipeline.zig).

The rest of the corpus tells the same story:

| Comptime operation | zig-analyzer | ZLS 0.16.0 |
| --- | --- | --- |
| Compose a type through `inline for` | Completes the final `trace` method | Completes the initial type, misses `trace` |
| Select a type indirectly through `@field` | Completes `verify` | Returns nothing at all |
| Select an API through a comptime condition | Offers the active `recordMetric`, excludes the dead `disabled` | Offers both, including the one that doesn't exist in your build |
| Reflected, parsed, recursively wrapped types | Resolves their generated members | Also resolves these — credit where due |

Receipts, not vibes: these results are pinned to Zig 0.16.0, compiler protocol
v4, and [ZLS 0.16.0 at commit
`4944862`](https://github.com/zigtools/zls/commit/494486203c3a48927f2383aa3d5ce5fca112186d),
kept as a versioned regression snapshot — including the cases where ZLS does
fine, so the corpus measures behavior instead of cherry-picking wins. The
[side-by-side gallery](https://mewhhaha.github.io/zig-analyzer/) shows the
exact code, cursor position, and captured response for every comparison.

To be fair, because someone will ask: ZLS has workspace symbols, cross-file
references, build-aware imports, and years of editor polish. Nobody is claiming
otherwise. The claim is narrower and, for comptime-heavy code, more important:
**syntax-derived possibilities and compiler-resolved facts are different
answers**, and only one of them is what your program does.

## Diagnostics ZLS simply does not have

Resolving the program also means catching code that compiles and is still
wrong. The compiler won't tell you. ZLS won't tell you. This will:

| You wrote | You get |
| --- | --- |
| An allocation with no visible release or ownership transfer | `unreleased-allocation` |
| An allocation, then another `try`, no `errdefer` between | `missing-errdefer`, with an insert-`errdefer` fix |
| `defer list.deinit();` … `return list.items;` | `returning-deinitialized-view` — congrats on the dangling slice |
| Returning `local_array[0..]` | `returning-local-slice` |
| Keeping `&list.items[i]` across an `append` | `invalidated-element-pointer` |
| Mutating a map while its iterator drives the loop | `iterator-invalidated-during-loop` |
| `@memcpy` between overlapping slices of one buffer | `aliased-memcpy` — that's UB, use `copyForwards` |
| Double free, use-after-free, overwritten owner — straight-line | `double-release`, `use-after-release`, `overwritten-owning-value` |
| `while (i >= 0) : (i -= 1)` on an unsigned index | `unsigned-reverse-loop` — it never terminates, then underflows |
| `count * size` passed straight to `alloc` | `allocation-size-overflow` |
| Byte-comparing a struct whose layout provably has padding | `padded-byte-compare` |
| `usize` field in a `packed` struct | `usize-in-packed-struct` |
| `operation() catch {};` | `discarded-error` |
| Returning memory owned by a locally deinitialized arena | `returning-arena-allocation` |

That's a sample; there are ~80 rules with stable codes, five severity levels,
cumulative style profiles (`official`, `idiomatic`, `strict`), ESLint-style
source suppressions, a project-wide `banned-identifier` list you configure
yourself, and quick fixes wherever the rewrite is mechanically provable —
including Zig-specific refactors ZLS has no equivalent for: exhaustive error
switches, `toOwnedSlice` returns, `defer`→`errdefer` ownership transfer,
tagged-union payload switches, `inline else` collapses, `assert(a and b)`
splitting, `orelse unreachable` → `.?`, and generated reflection members.

Run it without an editor, too:

```sh
zig-analyzer check .        # lint the project
zig-analyzer check --fix .  # apply only the provably-safe rewrites
```

## Does it at least not crash?

The bar for a language server is on the floor, so let's document clearing it:

- **Fuzzed against real code**: the full rule engine runs crash-free over
  TigerBeetle (244 files of the most disciplined Zig in existence) and the
  entire Zig standard library (550 files), plus ~6,100 deliberately truncated
  and mangled variants. Zero panics, zero hangs. Every false-positive class
  those corpora exposed got fixed with a regression test.
- **It found real bugs in std while we were at it**: a switch in
  `Build/Step.zig` missing a prong, and a leak on an error path in
  `Build/Fuzz.zig`. The linter pays rent.
- **Fast enough to run per keystroke**: worst file in the std corpus (`c.zig`,
  371 KB) analyzes in ~39 ms. It used to be 637 ms before the quadratic scans
  were hunted down, because of course there were quadratic scans.
- **A hung backend can't take your editor hostage**: every compiler request is
  under a watchdog; a wedged backend gets disconnected and the server degrades
  to syntax-only answers with one controlled restart. Mid-edit garbage,
  half-typed emoji, stale diagnostics against newer text, malformed protocol
  frames — all clamped, all tested. Your editor should never pay for our
  crashes.

## Now the disclaimer: this is a vibecoded pile

Read this part before you get attached. This project was substantially written
by an LLM agent swarm being pointed at its own review findings, in a handful of
sittings. The commit history says `ok`, `stuff`, and `uppiedates`. Draw your
own conclusions.

Concretely, that means:

- The lint rules are **token-stream heuristics**, not a real semantic model.
  They've been beaten against two large corpora until the false positives
  stopped, but "conservative pattern matching with several hundred tests" is
  the honest description. `semantic.zig` is 3,600 lines and knows it.
- The compiler backend requires a **patched Zig compiler pinned to an exact
  revision** (0.16.0). Zig moves; this will rot without maintenance.
- Analysis is per-file. There is no whole-program lifetime proof and it does
  not pretend otherwise — rules stay silent rather than guess.
- Several TASKS.md items are honestly marked incomplete. The watchdog has
  never met a real hostile backend, only simulated ones.

So no, this is not the production-grade comptime-aware Zig language server.
It's an existence proof with decent test coverage and a bad attitude. The
architecture is real (rules are self-contained modules with their own tests,
transport never leaks into analysis, every fix is compile-checked), the
approach — *ask the compiler, don't reimplement it* — is, we'd argue, the only
sane one, and all of it is sitting here under an MIT license.

**Fork it. Gut it. Take the rules and leave the rest.** If you want to build
the proper one, this is a running start: [ARCHITECTURE.md](ARCHITECTURE.md)
documents the module boundaries, [`src/rules/README.md`](src/rules/README.md)
documents the rule contract, and the corpus harness approach is described in
the PR history. Attribution is appreciated; permission is not required. That's
what the license is for.

## Try it

Requires Zig 0.16.0 exactly:

```sh
zig version   # must print 0.16.0
zig build
zig build backend           # builds the patched compiler backend
zig-out/bin/zig-analyzer doctor
```

The repo's own `.helix/languages.toml` uses the local analyzer:

```sh
hx examples/compiler/comptime_pipeline.zig
```

(`:workspace-trust`, then `:lsp-restart`, put the cursor after `pipeline.`
and request completion. Watch ZLS's answer next to it if you want the full
experience.)

Configure severities in `zig-analyzer.json`:

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

Suppress in source, ESLint-style — unknown rules and malformed directives warn
instead of silently doing nothing, because silent config is how trust dies:

```zig
// zig-analyzer: disable-next-line missing-errdefer
const buffer = try allocator.alloc(u8, 4);
```

The server speaks the whole LSP dialect you'd expect — diagnostics, code
actions, completion, hover, signature help, definition, references,
reflection-aware rename, call hierarchy, symbols, semantic tokens, inlay
hints, code lenses, formatting (delegated byte-for-byte to `zig fmt`, where it
belongs) — plus compiler-resolved comptime type hover and a
`zig-analyzer.peekResolvedType` code lens.

See [DEVELOPING.md](DEVELOPING.md) for the backend bootstrap and verification
suite, [examples/README.md](examples/README.md) for every comparison cursor,
and [TASKS.md](TASKS.md) for what's honestly done and what isn't.
