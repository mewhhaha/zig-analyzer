# zig-analyzer

**A compiler-backed Zig language server for codebases that actually use
`comptime`.**

ZLS is helpful while a program can be understood from its source syntax. Then
Zig starts generating types, selecting declarations with reflection, and
building APIs in `inline for` loops. At that point ZLS regularly loses the
concrete type: completion describes an intermediate value, returns nothing, or
cannot distinguish the active comptime branch.

That is not a niche edge case. It is how serious Zig libraries avoid repetition
and move work to compile time. Editor assistance should become more valuable as
the type logic gets harder, not disappear exactly when the code stops looking
like a conventional language.

`zig-analyzer` asks a patched Zig compiler what the program resolved to. It
keeps syntax-backed answers available while a file is incomplete, but uses
compiler facts for generated containers and values when syntax alone is not
enough. It also adds native correctness diagnostics and conservative fixes for
problems the compiler and ZLS do not report.

## Where ZLS breaks down

Consider a pipeline whose final type is assembled at comptime:

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

The program is valid and both language servers remain running. But completion
at `pipeline.` tells a very different story:

| Server | Completion candidates |
| --- | --- |
| zig-analyzer | `Self`, `inner`, `trace` |
| ZLS 0.16.0 | `value` |

ZLS reports a member of the initial `Source` type. It never follows the loop to
the final `Traced(Buffered(Source))` type, so the method used by the valid
program is missing from completion. zig-analyzer asks the compiler for the
resolved container and returns its actual members.

This is reproducible in
[`examples/compiler/comptime_pipeline.zig`](examples/compiler/comptime_pipeline.zig).
The broader corpus shows the same fault line:

| Comptime operation | zig-analyzer | ZLS 0.16.0 |
| --- | --- | --- |
| Compose a type through `inline for` | Completes the final `trace` method | Completes the initial type and misses `trace` |
| Select a type indirectly through `@field` | Completes `verify` | Returns no candidates |
| Select an API through a comptime condition | Includes active `recordMetric` and excludes inactive `disabled` | Offers both `recordMetric` and inactive `disabled` |
| Resolve reflected, parsed, and recursively wrapped types | Resolves their generated members | Resolves these cases too |

These results use Zig 0.16.0, compiler protocol v4, and
[ZLS 0.16.0 at commit
`4944862`](https://github.com/zigtools/zls/commit/494486203c3a48927f2383aa3d5ce5fca112186d).
They are a versioned regression snapshot, not a claim about every ZLS revision.
[ZLS documents comptime and semantic analysis as work in
progress](https://github.com/zigtools/zls/tree/0.16.0#features). The comparison
also includes cases where both servers agree so the corpus measures behavior
instead of assuming zig-analyzer wins every request.

## What is actually different from ZLS

ZLS 0.16.0 is a capable general-purpose Zig language server. It has workspace
symbols, cross-file references, build-aware imports, branching-type hover,
error-set switch completion, fix-all, import organization, and `zig fmt`
formatting. zig-analyzer is not claiming those features are absent. The
difference is what happens after source-level analysis stops being enough, and
what the tool can check beyond compiler errors.

| Area | zig-analyzer | ZLS 0.16.0 |
| --- | --- | --- |
| Analysis model | Uses a patched compiler protocol for resolved values and container shapes, with syntax fallback for incomplete files | Analyzes source and build metadata itself; its documentation describes comptime and semantic analysis as work in progress |
| Comptime branches | Reports the one active compiler-resolved type and its generated members | Can show all possible branching types, but does not necessarily determine the active branch |
| Native diagnostics | Configurable correctness, ownership, lifetime, comptime, testing, and idiom rules with stable codes and source suppressions | Parser/AstGen diagnostics, build-on-save compiler output, and a small built-in style diagnostic set |
| Project linting | `zig-analyzer check .` scans the project without an editor; `check --fix .` applies only the conservative CLI fix set | No standalone project lint-and-fix command |
| Editor fixes | Diagnostic quick fixes plus Zig-specific refactors, `source.fixAll`, and project-aware actions | Compiler quick fixes, discard fixes, string-literal conversions, `source.fixAll`, and import organization |
| Hover | Declarations and resolved types, plus reference help for keywords, `@` builtins, primitive types and values, literals, operators, and punctuation | Declarations and inferred types, `@` builtins, enum/field/label access, and compact primitive or literal summaries |
| Formatting | Delegates to `zig fmt` | Delegates to `zig fmt` |

The ZLS column is based on the pinned comparison build above, its
[0.16.0 release notes](https://zigtools.org/zls/releases/0.16.0/), and its
[documented editor actions](https://zigtools.org/zls/editors/vscode/). The
point is not that ZLS has no semantic features; it is that syntax-derived
possibilities and compiler-resolved facts are different answers for heavily
comptime-driven code.

The [side-by-side comparison gallery](docs/index.html) walks through the exact
code, request location, and captured response for completion, hover, warnings,
and compiler errors. Every result names the compared versions and links back to
its checked-in fixture.

## Useful diagnostics, not just completion

Resolving the program also makes it possible to find mistakes that are valid
Zig but are still likely to be wrong. zig-analyzer adds configurable findings
with stable rule names and editor quick fixes:

| Valid Zig source | zig-analyzer result | ZLS 0.16.0 result |
| --- | --- | --- |
| An allocator result with no visible release or ownership transfer | `unreleased-allocation` | No ownership diagnostic |
| Cleanup registered only with `errdefer` before a successful return | Explains that success leaks the allocation | No ownership diagnostic |
| Cleanup registered after another fallible operation | `cleanup-after-fallible-operation` with a move-cleanup action | No ownership diagnostic |
| Allocation released with the wrong method or allocator | `mismatched-allocation-release` | No ownership diagnostic |
| A straight-line second release, post-release use, or owning-value overwrite | `double-release`, `use-after-release`, or `overwritten-owning-value` | No ownership diagnostic |
| An opened file/directory, thread, mutex, or standard container without its matching cleanup | `missing-resource-cleanup` | No resource-lifetime diagnostic |
| A direct read or escape from a scalar/struct still initialized with `undefined` | `undefined-value-escape` | No initialization diagnostic |
| Returning `local_array[0..]` from a function | `returning-local-slice` explains that the backing storage expires | No diagnostic; the program compiles |
| Using `list.items` or a map iterator after a capacity-changing mutation | `invalidated-container-view` names the view, container, and mutation | No container-view lifetime diagnostic |
| Returning `list.items` while `defer list.deinit()` destroys the list | `returning-deinitialized-view` | No borrowed-view lifetime diagnostic |
| Returning memory owned by a locally deinitialized arena | `returning-arena-allocation` | No arena-lifetime diagnostic |
| Keeping `&list.items[index]` across a possible reallocation | `invalidated-element-pointer` | No element-pointer lifetime diagnostic |
| Reassigning a cleanup binding without releasing its previous resource | `defer-uses-reassigned-binding` | No deferred-capture ownership diagnostic |
| Returning an allocation or file that a normal `defer` frees or closes | `returning-released-value` links the return to its deferred release | No ownership-return diagnostic |
| Asserting `index <= values.len` immediately before `values[index]` | Opt-in `inclusive-index-bound` notes that the assertion itself is weaker than the access and offers a strict-bound fix | No weak-bound guidance |
| Counting down an explicit unsigned index with `index >= 0` and `index -= 1` | `unsigned-reverse-loop` explains the non-terminating condition and underflow | No diagnostic |
| Converting every error to `null`, `false`, or `0` | `error-collapsed-to-absence` | No diagnostic |
| Passing unchecked runtime multiplication as an allocation length | `allocation-size-overflow` | No release-mode overflow guidance |
| Cleaning a file/container only through `errdefer` | `resource-cleanup-on-error-only` | No success-path resource diagnostic |
| Mutating a map while its iterator drives the active loop | `iterator-invalidated-during-loop` | No iterator-lifetime diagnostic |
| Registering file/container cleanup after another `try` | `cleanup-after-fallible-operation` with a move-cleanup action | No resource-ordering diagnostic |
| `return err == error.NotFound;` | `error-value-comparison` | No diagnostic |
| `operation() catch {};` | `discarded-error` | No diagnostic |
| A proven fallible operation followed by `catch unreachable` | Opt-in `unsafe-catch-unreachable` | No diagnostic |
| Every caught error remapped to one value | Opt-in `lost-error-context` | No diagnostic |
| `return value + 1 << 2;` | `mixed-bitwise-arithmetic` with a parenthesizing fix | No diagnostic or fix |
| A proven unused private declaration | `unused-private-declaration` | No diagnostic |
| `@hasField`/`@hasDecl` names absent from a proven type shape | Opt-in `unknown-comptime-member` | No diagnostic |
| An explicitly comptime `if` whose condition is a literal | Opt-in `constant-comptime-condition` | No diagnostic |
| An allocation followed by a later `try` with no `errdefer` release | `missing-errdefer` with an insert-`errdefer` fix | No error-path leak diagnostic |
| `@memcpy` between possibly overlapping slices of one buffer | `aliased-memcpy` names the shared base and suggests `std.mem.copyForwards`/`copyBackwards` | No aliasing diagnostic |
| A `usize` or `isize` field inside a `packed` struct or union | `usize-in-packed-struct` explains the target-dependent layout | No layout diagnostic |
| `while (true)` whose body provably never exits or calls anything | `unconditional-busy-loop` | No diagnostic |
| `!comptime` applying the negation before the comptime expression | Opt-in `negated-comptime-expression` with a parenthesizing fix | No precedence diagnostic |
| A multi-line `if` body without braces | Opt-in `unbraced-multiline-if` with a brace-wrapping fix | No diagnostic |
| Any use of a project-banned identifier path | `banned-identifier` reports the configured path and hint | No diagnostic |
| `@intCast` narrowing a value whose wider type is visible, with no guard between | Opt-in `truncating-intcast` names the value and both types | No truncation diagnostic |
| Byte-comparing structs whose layout provably contains padding | `padded-byte-compare` explains the uninitialized padding bytes | No diagnostic |

Both servers still report Zig parser and compiler errors, and both can apply
the compiler's `var` to `const` fix. zig-analyzer's broader action set includes
missing switch-prong and struct-field scaffolding, boolean and cast
simplification, needless-`else` flattening, import organization, extraction,
missing-function generation, and a safe project-wide fix-all.

Zig-native selection actions go further where the language has no generic
refactoring equivalent:

- handle error unions with `try`, `catch`, or an exhaustive error switch, and
  handle optionals with `orelse` or payload capture;
- return `ArrayList` storage through `toOwnedSlice`, change successful ownership
  transfer from `defer` to `errdefer`, and make allocation overflow explicit;
- add mutable optional/tagged-union captures, convert tag tests to payload
  switches, repair format specifiers and argument tuples, and compose pointer
  casts;
- replace a proven uniform reflection loop with `inline else`, materialize a
  compiler-resolved type, and generate a member requested through reflection;
- update an open `build.zig` for a uniquely resolved package import, extract
  repeated identical `@cImport` blocks into a new wrapper, and generate Zig test
  harnesses for declarations;
- split a compound `assert(a and b)` into one assertion per condition, poison a
  `deinit` implementation with a final `self.* = undefined;`, and rewrite
  `expr orelse unreachable` to `expr.?`.

Ownership, generated-code, build, and C-interoperability actions are always
explicit. C-import extraction is returned only when the editor advertises
versioned workspace edits and file creation.

The analysis is deliberately conservative. Allocation warnings recognize
visible `free`/`destroy`, `defer` versus `errdefer`, ownership returns, field
storage, consuming calls, and arena lifetimes; they do not pretend to be a
path-sensitive proof. Style profiles separate official Zig guidance from more
opinionated idioms, and every rule can be overridden or suppressed.

Run the same analysis without an editor:

```sh
zig-analyzer check .
zig-analyzer check --fix .
```

`--fix` applies only locally provable rewrites such as boolean simplification,
compact single-statement defers, proven cast removal, and empty-`else`
removal. Scope-sensitive changes such as `var` to `const` and flattening an
`else` remain explicit editor actions, alongside allocation cleanup, generated
code, renames, and other judgment calls.

### Formatting

LSP formatting passes the document directly to `zig fmt` and returns its exact
result. Lint rewrites remain explicit quick fixes or `source.fixAll` actions,
and import organization remains a separate `source.organizeImports` action.
This keeps formatting identical to the Zig toolchain in editors, CI, and the
command line.

Configure severities in `zig-analyzer.json`:

```json
{
  "check": {
    "exclude": ["tests/syntax-fixtures"]
  },
  "lints": {
    "profile": "idiomatic",
    "correctness": "warning",
    "rules": {
      "discarded-error": "warning"
    },
    "banned": [
      { "path": "std.BoundedArray", "hint": "use stdx.BoundedArrayType" }
    ]
  }
}
```

Each `banned` entry names a complete dotted identifier path to reject, with an
optional `hint` appended to the diagnostic. Configuring a non-empty list turns
the `banned-identifier` rule on at warning severity; `lints.rules` can still
pick another severity.

`check.exclude` accepts project-relative files or directories. It is intended
for syntax, highlighting, and parser fixtures that deliberately contain code
which does not resolve; excluded paths are omitted only from recursive
`zig-analyzer check` scans.

The profiles are cumulative:

- `official` implements Zig's documented naming, fully-qualified namespace,
  underscore-prefix, file-name, and doc-comment guidance.
- `idiomatic` adds optional captures, direct `try` propagation, testing
  expectations, const pointer contracts, error-switch expansion, import
  cleanup, result-location initializers, conservative comptime cleanup,
  optional-capture reuse, direct boolean expressions, and compact defer forms.
- `strict` also requires documentation on public declarations and enables
  policy-heavy warnings for collapsed or remapped errors, vague public type
  names, and `catch`/`orelse unreachable` assertions.

For example, the idiomatic profile diagnoses and offers explicit rewrites for:

```zig
if (optional != null) use(optional.?);
const value = load() catch |err| return err;
try std.testing.expect(actual == 42);
const mode: Mode = Mode.fast;
const ready = if (state.isReady()) true else false;
defer { file.close(); }
if (ready) { use(value); } else {}
```

The actions use an optional capture, `try`, `expectEqual`, `.fast`, the boolean
condition, `defer file.close();`, and no empty `else`, respectively. These
syntax-bounded rewrites are available as quick fixes and safe fix-all edits
under `redundant-boolean-if`, `needless-defer-block`, and
`needless-empty-else`. Renames, file naming, pointer constness, and other
API-facing changes are never formatter or fix-all edits.

The idiomatic testing rules prefer `expectEqualStrings`, `expectEqualSlices`,
and `expectError` when an exact equivalent is proven. They also diagnose manual
floating-point epsilon assertions, collapsed errors, unused error/switch
captures, boolean optional-capture tests, and hand-built zero terminators.
Only exact rewrites participate in fix-all; approximate comparisons and
sentinel construction remain advisory.

Project checks normalize relative imports and report different spellings of
the same module, repeated `@cImport` translations, test files absent from both
the import graph and `build.zig`, and conflicting target/optimization settings
for the same root source. These require a directory scan, so they are emitted
by `zig-analyzer check .` rather than guessed from one open document.

Rules live under `src/rules`. Syntax-local rules have one module containing
their diagnostic, fixes, and tests; analyses that require the same binding or
compiler-shape proof share a lifecycle engine. A common context applies levels
and suppressions, and one registry provides deterministic composition. The
extension contract is documented in [`src/rules/README.md`](src/rules/README.md).

Rules accept `off`, `hint`, `information`, `warning`, and `error`. Per-rule
settings override their tier. Source suppressions use ESLint-style comments:

```zig
// zig-analyzer: disable-file rule-a, rule-b
const first = value(); // zig-analyzer: disable-line rule-a
// zig-analyzer: disable-next-line rule-a, rule-b
const second = value();
// zig-analyzer: disable rule-a, rule-b
const third = value();
// zig-analyzer: enable rule-a
const fourth = value();
// zig-analyzer: enable all
```

Omitting the rule list, or naming `all`, targets every rule. `disable` remains
active until a matching `enable`; `disable-file` must appear before code.
Unknown rules, malformed directives, and malformed configuration produce
warnings instead of silently doing nothing.

## Try it

zig-analyzer currently requires Zig 0.16.0:

```sh
zig version # must print 0.16.0
zig build
zig build backend
zig-out/bin/zig-analyzer doctor
```

The repository's `.helix/languages.toml` runs the local analyzer, so a quick
comptime comparison is:

```sh
hx examples/compiler/comptime_pipeline.zig
```

On Helix versions with workspace trust enabled, run `:workspace-trust` once
and then `:lsp-restart`. Put the cursor after `pipeline.` on the return line and
request completion.

The server supports diagnostics and code actions, completion, hover, signature
help, definition, references, reflection-aware rename, call hierarchy, document
and workspace symbols, semantic tokens, inlay hints, code lenses, and
formatting. It completes local `@import` paths and format placeholders, shows
implicit enum values, and exposes compiler-resolved comptime types through
hover and a `zig-analyzer.peekResolvedType` code-lens command. Hover also
describes Zig keywords, builtins, primitive types and values, literals,
operators, and punctuation with links to the language reference. It remains
experimental and pins an exact Zig compiler revision.

See [DEVELOPING.md](DEVELOPING.md) for backend bootstrapping, the full
verification suite, and the Helix test workflow, and
[ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries and extension points. See
[examples/README.md](examples/README.md) for every comparison cursor, and
[TASKS.md](TASKS.md) for implementation status.
