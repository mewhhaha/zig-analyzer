# Language-server comparison examples

The completion, hover, navigation, and rename sources compile with Zig 0.16.0.
Run those example tests with:

```sh
zig build examples
```

`diagnostics/compiler_error.zig` is intentionally excluded from that build. It
is valid Zig syntax with a semantic return-type error, so opening it exercises
the `zig compiler` diagnostic path rather than the parser diagnostic path.

`diagnostics/code_actions.zig` is also intentionally incomplete. Open it in
Helix and use `space a` on the affected expression to exercise switch-prong and
struct-field filling, `var` to `const`, boolean simplification, generated
functions, and import organization. Select exactly `enabled == true` before
requesting the extract-constant refactor. Run the fix-all source action to see
only semantics-preserving rewrites applied; scaffolding and generation remain
explicit actions. The repository configuration enables the `idiomatic` profile,
so the mixed-operator parentheses action and other style diagnostics are visible
without changing configuration. The error comparison is a correctness warning
and intentionally has no automatic rewrite because introducing a `switch` is
context-dependent.

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
file and `build.zig` are both open. Repeated `@cImport` extraction additionally
requires a client that supports workspace file creation.

Open `diagnostics/idiomatic_style.zig` for the style-guide actions. It covers a
redundant fully-qualified type name, optional force-unwrapping after a null
check, direct error propagation, a generic testing expectation, a mutable
pointer used only for reads, and type names repeated despite a known result
location. It also demonstrates a returned slice backed by an expired local
array, cleanup registered after a fallible operation, a force-unwrap that
ignores an existing optional capture, and byte equality that should use
`expectEqualStrings`. These remain valid Zig so every diagnostic can be
inspected and applied independently. The same fixture covers exact
`expectEqualSlices` and `expectError` rewrites, an advisory approximate-float
expectation, errors collapsed to absence, an optional capture used only as a
presence test, and a manually appended zero terminator. It also shows quick
fixes for boolean-valued `if` expressions, one-statement `defer` blocks, and
empty `else` branches; all three are safe fix-all rewrites. Formatting itself
remains the exact output of `zig fmt`.

Open `diagnostics/memory_management.zig` to exercise memory ownership warnings.
`forgottenRelease` warns because its allocation has no cleanup. `errorPathOnly`
also warns because `errdefer` cleans up only when the function returns an error.
`releasedCorrectly` stays clean because its normal `defer` covers every exit.
`cleanupRegisteredTooLate` warns because the second allocation can fail before
cleanup for the first allocation is registered; its quick fix moves the first
`defer` directly after the first allocation.

Open `diagnostics/lifetime_mistakes.zig` for compiler-missed borrowed-storage
mistakes. It returns views from destroyed containers and arenas, keeps an
element pointer across an `ArrayList` growth, reassigns a deferred cleanup
binding, relies on error-only file cleanup, multiplies an allocation length,
and mutates a map during iteration. The functions are referenced but not run,
so the file remains a safe compilation fixture while every diagnostic is
visible in the editor.

For completion cases, leave the source unchanged and place the cursor directly
after the listed dot, before the existing member name:

| File | Cursor expression | Expected member |
| --- | --- | --- |
| `compiler/comptime_pipeline.zig` | `pipeline.` | `trace` |
| `compiler/indirect_type_lookup.zig` | `ActiveImplementation.` | `verify` |
| `compiler/conditional_api.zig` | `ActiveApi.` | `recordMetric` |
| `compiler/reflected_strategy.zig` | `ReadingStrategy.` | `encode` |
| `compiler/parsed_configuration.zig` | `ResilientClient.` | `retryBudget` |
| `compiler/recursive_wrapper.zig` | `wrapped.` | `unwrap` |
| `zls/struct_fields.zig` | `profile.` | `display_name`, `login_count` |
| `zls/stdlib_completion.zig` | `std.mem.` | `eql` |
| `zls/imports/main.zig` | `catalog.` | `default_limit`, `clampToLimit` |

The remaining rename case is `zls/scoped_rename.zig`. Rename the `value`
parameter of `increment` to `number`. A scope-aware result changes that
parameter and the use on the following line, while leaving the unrelated
`value` parameter in `describe` untouched.

Use `zls/hover.zig` to exercise hover resolution. Hover both uses of `incoming`,
the `doubled` local at the call site, `addSample`, and `retry_limit`. The results
show declared types for parameters and locals, the function signature and doc
comment, and the bounded constant value. The field, import, and standard-library
examples also provide contextual hover information for `display_name`,
`clampToLimit`, and `eql` respectively.

Hover also follows an inferred local initialized by a function call when the
function has an explicit return type. Imported dotted types, nested namespace
aliases, and private backing structs are followed to the final field, so a field
such as `slice: []const Header` retains its declaration and documentation even
when the local itself has no type annotation.

To compare in Helix, first use this repository's default local configuration:

```sh
zig build backend
zig build
hx examples/compiler/comptime_pipeline.zig
```

After testing zig-analyzer, temporarily change the `language-servers` entry in
`.helix/languages.toml` from `zig-analyzer-local` to `zls`, run
`:lsp-restart`, and repeat the same requests with ZLS 0.16.0. Restore the local
entry afterward so Helix uses this repository's analyzer again.
