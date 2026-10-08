# Language-server examples

The completion, hover, navigation, and rename sources compile with Zig 0.17.0.
Run those example tests with:

```sh
zig build examples
```

`diagnostics/compiler_error.zig` is intentionally excluded from that build. It
is valid Zig syntax with a semantic return-type error and is used by the
compiler-integration tests.

`diagnostics/code_actions.zig` is also intentionally incomplete. Open it in
Helix and use `space a` on the affected expression to exercise switch-prong and
struct-field filling, `var` to `const`, boolean simplification, generated
functions, and import organization. Select exactly `enabled == true` before
requesting the extract-constant refactor. Run the fix-all source action to see
only semantics-preserving rewrites applied; scaffolding and generation remain
explicit actions. The repository configuration enables the `idiomatic` profile,
so the mixed-operator parentheses action and other style diagnostics are visible
without changing configuration. The error-value diagnostic is a correctness
warning and intentionally has no automatic rewrite because introducing a
`switch` is context-dependent.

The lower half of that fixture exercises the Zig-native action registry. Request
actions on `fallible()`, `optional()`, `values.items`, the ownership `defer`, the
inclusive index assertion, unsigned reverse loop, payload mutation and tag
check, the format string, allocation product, pointer assignment, reflective
loop, `Generated`, and the reflection member string. These cover error/optional
recovery, an ownership return invalidated by `defer`, an off-by-one bound, an
unsigned countdown underflow, mutable captures, tagged-union switches, format
and overflow repair, pointer casts, `inline else`, resolved-type materialization,
reflected-member generation, and test harnesses.
Format calls with a simple missing or extra tuple argument also offer an explicit
arity repair.
Build-module repair appears on a package `@import` when its uniquely named Zig
file and `build.zig` are both open.

## Diagnostic fixtures

Every file under `diagnostics/` marks the findings it must produce with a
`// expect: <rule-code>[, <rule-code>...]` comment. A marker on its own line
applies to the next line; a marker after code applies to that line (used where
a finding anchors at the first byte of the file). `tests/example_diagnostics.zig`
runs the file and project engines over each fixture with this repository's
`zig-analyzer.json` and requires exactly the marked (line, rule) set, so a
missing or an unexpected finding fails `zig build test`. Add a marker whenever
you add an offending line, and the table below with it: the test also fails
when the generated block between the two comments differs from the markers.

<!-- diagnostics:begin -->
| File | Rules reported |
| --- | --- |
| `diagnostics/action_results.zig` | `unsafe-orelse-unreachable`, `non-exhaustive-switch-else`, `prefer-log-over-print` |
| `diagnostics/code_actions.zig` | `unsorted-imports`, `unused-import`, `never-mutated-var`, `missing-struct-field`, `missing-switch-prong`, `redundant-bool-comparison`, `mixed-bitwise-arithmetic`, `unresolved-call`, `returning-deinitialized-view`, `returning-released-value`, `inclusive-index-bound`, `unsigned-reverse-loop`, `prefer-log-over-print`, `allocation-size-overflow` |
| `diagnostics/compiler_error.zig` | none |
| `diagnostics/dangling_slice.zig` | `never-mutated-var`, `returning-local-slice` |
| `diagnostics/discarded_error.zig` | `discarded-error` |
| `diagnostics/helper_release.zig` | `unreleased-allocation` |
| `diagnostics/idiomatic_style.zig` | `redundant-qualified-name`, `mutable-pointer-parameter`, `prefer-optional-capture`, `prefer-try`, `prefer-testing-expect-equal`, `redundant-type-qualification`, `prefer-anonymous-initializer`, `never-mutated-var`, `returning-local-slice`, `unsafe-orelse-unreachable`, `redundant-optional-unwrap`, `cleanup-after-fallible-operation`, `error-collapsed-to-absence`, `redundant-boolean-if`, `needless-defer-block`, `needless-empty-else`, `prefer-optional-presence-test`, `prefer-sentinel-termination`, `prefer-testing-expect-equal-strings`, `prefer-testing-expect-equal-slices`, `prefer-testing-expect-approx`, `prefer-testing-expect-error` |
| `diagnostics/lifetime_mistakes.zig` | `returning-deinitialized-view`, `returning-arena-allocation`, `invalidated-element-pointer`, `defer-uses-reassigned-binding`, `resource-cleanup-on-error-only`, `allocation-size-overflow`, `iterator-invalidated-during-loop` |
| `diagnostics/memory_management.zig` | `unreleased-allocation`, `cleanup-after-fallible-operation`, `missing-errdefer` |
| `diagnostics/overlapping_copy.zig` | `aliased-memcpy` |
| `diagnostics/padded_equality.zig` | `padded-byte-compare` |
| `diagnostics/unsigned_reverse_loop.zig` | `unsigned-reverse-loop` |
| `diagnostics/use_after_release.zig` | `use-after-release`, `double-release` |
<!-- diagnostics:end -->

All fixtures except `compiler_error.zig` (a semantic error only the compiler
reports) and `code_actions.zig` (intentionally incomplete) are valid Zig that
the compiler accepts. Use them as follows:

- `idiomatic_style.zig` is the style-guide tour: each marked line has an
  independent quick fix, and the semantics-preserving ones are fix-all
  rewrites. Formatting itself remains the exact output of `zig fmt`.
- `memory_management.zig` pairs warnings with clean functions: `releasedCorrectly`
  stays clean because its normal `defer` covers every exit, and the quick fix
  for `cleanup-after-fallible-operation` moves the first `defer` directly after
  the first allocation.
- `lifetime_mistakes.zig` is compiler-missed borrowed-storage mistakes. Its
  functions are referenced but not run, so the file stays a safe compilation
  fixture.
- The single-purpose fixtures (`overlapping_copy.zig`, `padded_equality.zig`,
  `discarded_error.zig`, `use_after_release.zig`, `dangling_slice.zig`,
  `helper_release.zig`, `unsigned_reverse_loop.zig`) each isolate one program
  the compiler accepts but zig-analyzer warns about.

The `lsp/` and `compiler/` examples are editor interaction fixtures (cursor
positions for completion, hover and rename, below) rather than lint cases, so
they carry no markers; the same test requires them to be finding-free.

For compiler-derived completion cases, leave the source unchanged and place the
cursor directly after the listed dot, before the existing member name:

| File | Cursor expression | Expected candidates |
| --- | --- | --- |
| `compiler/comptime_pipeline.zig` | `pipeline.` | `Self`, `inner`, `trace` |
| `compiler/indirect_type_lookup.zig` | `ActiveImplementation.` | `verify` |
| `compiler/conditional_api.zig` | `ActiveApi.` | `recordMetric` |
| `compiler/parsed_configuration.zig` | `ResilientClient.` | `retryBudget` |
| `compiler/reflected_strategy.zig` | `ReadingStrategy.` | `encode` |
| `compiler/reified_flags.zig` | `flags.` | `verbose`, `cache`, `trace` |

The recursive wrapper remains a compiler regression fixture. Its useful
members are `inner` and `unwrap`.

The `lsp` fixtures cover syntax-backed cases. Struct fields expose
`display_name` and `login_count`, standard-library completion includes `eql`,
and the imported catalog exposes `default_limit` and `clampToLimit`.

The rename case is `lsp/scoped_rename.zig`. Rename the `value`
parameter of `increment` to `number`. A scope-aware result changes that
parameter and the use on the following line, while leaving the unrelated
`value` parameter in `describe` untouched.

Use `lsp/hover.zig` to exercise hover resolution. Hover both uses of `incoming`,
the `doubled` local at the call site, `addSample`, and `retry_limit`. The results
show declared types for parameters and locals, the function signature and doc
comment, and the bounded constant value. The field, import, and standard-library
examples also provide contextual hover information for `display_name`,
`clampToLimit`, and `eql` respectively.

Use `lsp/language_hover.zig` to exercise language hover. Hover `const`, `bool`,
`true`, `@sizeOf`, and the statement terminators. zig-analyzer documents Zig
language tokens as well as declarations.

Hover also follows an inferred local initialized by a function call when the
function has an explicit return type. Imported dotted types, nested namespace
aliases, and private backing structs are followed to the final field, so a field
such as `slice: []const Header` retains its declaration and documentation even
when the local itself has no type annotation.

To exercise the examples in Helix, use this repository's local configuration:

```sh
zig build backend
zig build
hx examples/compiler/comptime_pipeline.zig
```
