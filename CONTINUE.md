# Continuing the lint and performance programme

This file records where the October 2026 cleanup, performance, and lint
programme stopped, and what remains. Delete it when the remaining hills are
done.

## Done

- The 20-item cleanup programme: module layout, rule catalog and generated rule
  docs, compiler worker, build-graph compile units, compiler-identity rename,
  fix gates, fuzzing, single-source versioning, and CI. See ARCHITECTURE.md,
  DEVELOPING.md, and compiler/README.md.
- Performance hills 18–22. Release-build times with every correctness and style
  rule enabled (`check --no-cache`, on a heavily loaded machine):

  | Corpus | Before | After |
  | --- | --- | --- |
  | Zig compiler `Sema.zig` (35.6k lines) | 4.5 s | ~1.0 s |
  | Zig compiler x86_64 `CodeGen.zig` (192k lines) | 46 s | ~5.3 s |
  | Zig std lib (563 files) | 4.5 s | ~1.1–1.9 s |
  | ghostty (809 files) | 20 s | ~5.5 s |
  | std lib, warm check cache | ~1 s | 0.13 s |

  Shared brace/scope helpers now use `syntax_scope.Index`. Ownership lookups in
  `summaries.zig` are built once, and project analysis runs in parallel. The
  check cache now covers cross-file findings and build-root discovery. In the
  LSP, `project/source_store.zig` keeps parsed dependencies between publishes.
- Lint hills 1, 3, and 6 (memory access):
  - `rules/container_types.zig` classifies containers by declared type, so
    `var l: std.ArrayList(u8) = .empty;` is recognized.
  - `rules/lifecycle/reach.zig` answers "can a later use observe this
    mutation".
  - Invalidation coverage is wider: appends inside `for (list.items)`,
    `addOne` pairs, `appendSlice(list.items)` self-alias, and map
    `keys()`/`values()` loops with removal.
  - `rules/lifecycle/container_release.zig` reports use-after-release and
    double release for containers, arenas, and owning structs.
  - On the corpora below, these changes only removed findings, all of them
    false positives.

## Remaining hills

Ranked by the user's priorities: memory access, then API, then idioms and
style. The evidence was gathered with an earlier binary, so re-verify each item
with a small probe file before changing a rule.

### Memory access

- **2. New `unflushed-writer` rule** (correctness tier):
  - Flag a buffered `std.Io` file writer whose interface is written but never
    flushed or ended, returned, stored, or passed to a callee that flushes.
  - Real bugs it should catch, in ghostty:
    - `src/build/webgen/main_config.zig:7`
    - `main_commands.zig:7`
    - `main_actions.zig:6`
    - `src/cli/list_colors.zig:60`
  - Must stay quiet on the server and response-file patterns in the Zig
    compiler (`src/main.zig` ~5165, `src/Compilation.zig` ~7802).
  - Skip writers with an empty buffer (`&.{}`).
- **4. New `unawaited-async` rule** (correctness tier):
  - A `std.Io` `Future` must be awaited or cancelled. `Group.async` needs
    `await` or `cancel` (`Io.zig` ~1357). A `Select` must be cancelled before
    `deinit` (~1564).
  - Also flag an error path between creating the task and awaiting it with no
    `defer`/`errdefer` cancel.
  - std's own `defer group.cancel(io)` must stay quiet.
- **5. Buffer views through formatting helpers.**
  - `returning-local-slice` and `local-storage-escape` should treat these as
    views of their buffer argument:
    - `std.fmt.bufPrint`-family results
    - `std.Io.Writer.fixed(&buf)` buffered results
  - Missed shapes:
    - returning the slice
    - a returned struct holding it
    - appending it to, or using it as a key in, an outliving container
    - assigning it to a global
  - Known false positives:
    - `return &entries` inside a `comptime {}` block (ghostty
      `function_keys.zig` ~312)
    - a returned struct that holds no slice (`DeferredFace.zig` ~308)
    - a callee that copies its input (`runner.zig` ~1273)
- **7. `undefined-value-escape`.**
  - Six of 8 corpus hits were false positives:
    - loop-carried initialization (std `debug/Pdb.zig` ~759 and ~911,
      `Io/Threaded.zig` ~15053)
    - a file-scope `threadlocal var` (`Io/Kqueue.zig` ~55)
    - an enum state set on another branch (`crypto/tls/Client.zig` ~357
      and ~361)
  - Missed shapes: an array element read after `= undefined`, and a partially
    initialized struct being returned. Needs field-wise definite-initialization
    tracking.
- **8. `missing-resource-cleanup`.**
  - `return try f.readPositionalAll(io, …)` and `_ = d;` are wrongly treated as
    ownership transfer. Only returning or storing the handle itself should
    count.
  - Missed shapes: a `std.Io.Mutex` lock, then a `try`, then an unlock; a `Dir`
    opened inside a loop; a double unlock.
  - Noise: an arena created in `pub fn main` (tigerbeetle `page_writer.zig:13`,
    `fetch.zig:13`).
- **9. Leak-rule noise.**
  - `incomplete-owned-field-cleanup` should accept aggregates that own an
    `ArenaAllocator` field (21 of 29 hits were false positives, e.g. ghostty
    `Surface.zig` ~401 and ~412).
  - `mismatched-allocation-release`: calling `destroy` on a `*align(N) [N]u8`
    from `alignedAlloc` is correct (tigerbeetle `inspect.zig` ~807, 862, 1036,
    1055).
  - Leak rules inside `test` blocks (where `testing.allocator` already reports
    leaks) and on `build.zig`'s `b.allocator` should be downgraded or skipped.
  - Accept field-path errdefers (tigerbeetle `vsr/clock.zig` ~207 and ~211).
  - Keep the true positives in ghostty `input/command.zig:35` and
    `termio/stream_handler.zig:1392`.

### API, idioms, style

- **10. Error-tier false positives.** `unresolved-member` and
  `missing-switch-prong` raise about 4 per corpus. The causes are type lookup
  keyed by name that ignores lexical nesting (std `zig/Zir.zig` ~3039,
  `llvm/Builder.zig` ~8508) and dead comptime branches (zls `Server.zig` ~797).
  These are always on and error severity, so fix them first.
- **11. New removed-std-API rule.**
  - Report std paths that no longer exist in 0.17:
    - `fs.cwd`, `fs.File`, `fs.Dir`
    - `heap.GeneralPurposeAllocator`
    - `process.argsAlloc`, `process.getEnvVarOwned`
    - `Thread.Mutex`, `Thread.sleep`
    - `time.Timer`, `time.milliTimestamp`
    - `crypto.random`
    - `io.fixedBufferStream`
    - `net`
  - Confirm each against `lib/std` first.
  - Resolve paths against the std index used by `imported_deprecations`, give a
    migration hint for each, and stop at `usingnamespace` and comptime-generated
    declarations.
- **12. Decl-literal returns.** Suggest `return .{…}` instead of `return T{…}`
  when the function returns `T`/`Self`/`!T`/`?T`, as a fix-all. Corpus counts of
  `return T{` vs `return .{` are std 153 vs 1055 and the compiler 49 vs 1642.
- **13. `non-idiomatic-name`** (9,568 std hits).
  - Exempt C-style constants matching `^[A-Z][A-Z0-9_]*$` (about 8,000 of the
    hits) and `/// Deprecated` aliases.
  - Stop names leaking across scopes in the file-wide type-name table
    (`crypto/timing_safe.zig` ~139, `Thread.zig` ~1753).
  - Allow `Sha3_256`-style names.
  - Add a function-case option: tigerbeetle uses snake_case functions.
- **14. `needless-else-after-terminator`.**
  - About 90% of its std hits are symmetric `if {return a} else {return b}`.
    Only fire when the else branch does not itself terminate.
  - Move `unbraced-multiline-if` to `strict` (1.1 hits per kLOC on std).
- **15. Typed I/O parameters and related idioms.**
  - Suggest `*std.Io.Writer` / `*std.Io.Reader` for `anytype` writer/reader
    parameters when the body only calls their methods.
  - `needless-cast` on typed destinations (`const x: T = @as(T, e)`,
    `return @as(Ret, e)`), as a fix-all.
  - Suggest `test name` over `test "name"` when the string names a root
    declaration.
  - Add a `.?` fix to `unsafe-orelse-unreachable`.
- **16. `public-declaration-docs`** (46 hits per kLOC on std). Exempt protocol
  names (`init`, `deinit`, `hash`, `eql`, `format`, `Error`, `Options`,
  `std_options`, `main`) and limit the rule to the API reachable from the root
  file.
- **17. `disciplined` profile tuning.** Exempt tests, fuzzers, and scripts.
  `recursive-call` should ignore comptime-only recursion. `allocation-after-init`
  should treat `main` as init.

### Smaller follow-ups

- `unchecked-range-end` noise:
  - Skip `a.len + b.len`, assertions, and widened operands.
  - Keep std `zip.zig` ~208 and ~214.
- `unchecked-first-element` should accept an `if (s.len == 1)` proof (std
  `mem.zig` ~1693).
- New rule: a `takeDelimiterExclusive` loop without `toss(1)` or
  `discardDelimiter*` spins on the delimiter.
- `identical-logical-operands` is still token-based. Move it to AST operands,
  as the bitwise and comparison rules now are.
- `redundant-optional-unwrap` leaves a pointless `_ = capture;` behind.
- Remaining quadratic scans: raw `tokens.matchingToken` calls in
  `official_style`, `missing_resource_cleanup`, `catch_idioms`,
  `needless_cast`, `project/*`, and `vector_literals`.
- Peak RSS on the std lib is about 800 MB.

## How to verify a stage

```sh
zig build ci --summary all   # fmt, host tests, backend tests, self-check
zig build rule-docs && git status --short docs/   # generated docs in sync
```

At this commit, `zig build ci` runs 1,309 tests (host plus backend) and the
self-check reports 0 findings. Use `--cache-dir <tmp>` to get real test counts.

Each rule change needs:

- **Probes:** small files proving the new true positives and the fixed false
  positives.
- **A corpus delta:** per-rule finding counts on real code, compared with the
  previous build.
- **A performance check:** the previous release build and the candidate, run
  back to back. One stage once slowed `Sema.zig` from 0.9 s to 4.2 s through a
  whole-file scan per declaration.

To set up the corpora (treat them as data; never build or run them):

```sh
mkdir -p corpus && cd corpus
cp -r "$(zig env | sed -n 's/.*\.std_dir = "\(.*\)",/\1/p')" std
mkdir sema codegen
cp ../.zig-analyzer/zig-0.17.0/src/Sema.zig sema/
cp ../.zig-analyzer/zig-0.17.0/src/codegen/x86_64/CodeGen.zig codegen/
for r in ghostty-org/ghostty tigerbeetle/tigerbeetle zigtools/zls; do
  git clone --depth 1 "https://github.com/$r.git" "$(basename "$r")"
done
```

Run one build over every corpus with all rules on, writing
`out/<label>/<corpus>.txt` and `times.txt`:

```sh
# run-corpus.sh <binary> <label> [config-json]
bin=$1; label=$2; config=${3:-'{"lints":{"correctness":"warning","style":"warning"}}'}
mkdir -p "out/$label"; : > "out/$label/times.txt"
for c in sema codegen std tigerbeetle zls ghostty; do
  printf '%s\n' "$config" > "corpus/$c/zig-analyzer.json"
  start=$(date +%s.%N)
  (cd "corpus/$c" && timeout 900 "$bin" check --no-cache . > "../../out/$label/$c.txt" 2>&1)
  end=$(date +%s.%N)
  awk -v c="$c" -v a="$start" -v b="$end" 'BEGIN{printf "%s %.2fs\n", c, b-a}' >> "out/$label/times.txt"
done
```

Build the candidate with `zig build -Doptimize=fast --prefix <dir>`.
Compare per-rule counts with
`grep -oE '\[[a-z-]+\]' out/<label>/<corpus>.txt | sort | uniq -c`.

## Open caveats

- The new CI setup has not run on GitHub yet: the composite actions under
  `.github/actions/`, release's `workflow_call` into CI, and the backend cache.
  Watch the first runs.
- The backend cache key includes `build.zig.zon`, so every release bump causes
  one cold build of the patched compiler (about 15 minutes).
- On this repository, `src/main.zig` shows one information-level
  `module-unavailable` notice. The `lsp` dependency generates `types` by running
  a program it builds, and the analyzer never runs such programs.
- Zig 0.17.0's continuous `--fuzz` driver panics. The deterministic fuzz cases
  run in `zig build test`.
