# Rule reference

Each diagnostic links to documentation stored beside the rule implementation.
The rule page explains the proven pattern, why it matters, and when the rule is
appropriate.

Semantic diagnostics are errors, correctness rules are warnings, and style rules
are off until enabled by a profile, the style tier, or a per-rule setting.

## Always-on semantic diagnostics

- [`unresolved-call`](unresolved-call.md) — Reports an unqualified call whose
  function cannot be found in the analyzed scope.
- [`unresolved-identifier`](unresolved-identifier.md) — Reports an unqualified
  non-call identifier that cannot be found in the analyzed scope.
- [`unresolved-member`](unresolved-member.md) — Reports a field, declaration,
  or method missing from a receiver whose complete local shape is known.
- [`unresolved-label`](unresolved-label.md) — Reports a `break` or `continue`
  targeting a label that is not visible from the branch.
- [`missing-switch-prong`](missing-switch-prong.md) — Reports a switch over a
  proven finite enum or tagged union that omits cases and has no `else` prong.
- [`missing-struct-field`](missing-struct-field.md) — Reports a struct
  initializer that omits required fields without defaults.
- [`never-mutated-var`](never-mutated-var.md) — Reports a local `var` whose
  binding and reachable mutable aliases are never mutated.

## Contract and compiler-backed project rules

- [`import-boundary`](import-boundary.md) — Reports imports denied by declared
  project architecture contracts.
- [`discarded-must-use`](discarded-must-use.md) — Reports explicitly discarded
  returns from declared must-use callables.
- [`configuration-divergent-api`](configuration-divergent-api.md) — Reports
  public API shapes that differ across compiler-analyzed compile units.
- [`unreachable-public-declaration`](unreachable-public-declaration.md) —
  Reports public declarations absent from every analyzed compile unit.

Contract rules activate when their corresponding project contract is present.
Compiler-backed project rules are opt-in.

## Default correctness warnings

- [`unreleased-allocation`](unreleased-allocation.md) — Reports a mechanically
  identified allocation with no visible matching release or ownership return
  before scope exit.
- [`defer-cleanup-in-loop`](defer-cleanup-in-loop.md) — Reports cleanup deferred
  to a surrounding function scope from inside a loop.
- [`error-value-comparison`](error-value-comparison.md) — Reports equality
  comparisons against a concrete error value.
- [`cleanup-after-fallible-operation`](cleanup-after-fallible-operation.md) —
  Reports cleanup registered only after another fallible operation can exit the
  scope.
- [`mismatched-allocation-release`](mismatched-allocation-release.md) — Reports
  an allocation released with the wrong method or through a different allocator.
- [`double-release`](double-release.md) — Reports more than one visible release
  of the same allocation in one control-flow scope.
- [`use-after-release`](use-after-release.md) — Reports a visible use of an
  allocation after its matching release.
- [`overwritten-owning-value`](overwritten-owning-value.md) — Reports assignment
  over an owning binding before its previous allocation is released.
- [`missing-resource-cleanup`](missing-resource-cleanup.md) — Reports a
  recognized resource or mutex with no visible cleanup, unlock, or ownership
  transfer.
- [`undefined-value-escape`](undefined-value-escape.md) — Reports a value
  initialized with `undefined` that is read or escapes before whole-value
  initialization.
- [`returning-local-slice`](returning-local-slice.md) — Reports a returned slice
  that points into a local array.
- [`invalidated-container-view`](invalidated-container-view.md) — Reports a
  slice or iterator used after an operation that may move or invalidate its
  container's backing storage, including `realloc` of the source allocation.
- [`returning-deinitialized-view`](returning-deinitialized-view.md) — Reports a
  returned view whose backing container is deinitialized by a deferred cleanup
  during return.
- [`returning-arena-allocation`](returning-arena-allocation.md) — Reports a
  returned value allocated from a local arena that is deinitialized before the
  function finishes returning.
- [`invalidated-element-pointer`](invalidated-element-pointer.md) — Reports a
  pointer into a container's elements used after an operation that may
  reallocate the backing storage.
- [`defer-uses-reassigned-binding`](defer-uses-reassigned-binding.md) — Reports
  a binding reassigned after deferred cleanup captures it by name.
- [`allocation-size-overflow`](allocation-size-overflow.md) — Reports unchecked
  runtime multiplication used as an allocation length.
- [`resource-cleanup-on-error-only`](resource-cleanup-on-error-only.md) —
  Reports a resource cleaned up by `errdefer` only, with no successful-path
  cleanup or ownership transfer.
- [`iterator-invalidated-during-loop`](iterator-invalidated-during-loop.md) —
  Reports mutation of a map while an iterator over that map is active.
- [`duplicate-module-import`](duplicate-module-import.md) — Reports two import
  spellings in one file that resolve to the same Zig module path.
- [`returning-released-value`](returning-released-value.md) — Reports a returned
  owning value that is released by a defer as the function exits.
- [`unsigned-reverse-loop`](unsigned-reverse-loop.md) — Reports a descending
  unsigned loop whose condition remains true at zero and whose update then
  underflows.
- [`missing-errdefer`](missing-errdefer.md) — Reports an owning acquisition or
  partial construction followed by another fallible operation without an
  intervening error-path release.
- [`copied-io-interface`](copied-io-interface.md) — Reports a standard I/O
  interface copied away from implementation state used by its callbacks.
- [`directory-iteration-not-enabled`](directory-iteration-not-enabled.md) —
  Reports iteration of a directory opened without enabling iteration.
- [`discarded-read-count`](discarded-read-count.md) — Reports discarded byte
  counts from partial-read methods.
- [`discarded-realloc-result`](discarded-realloc-result.md) — Reports a
  discarded replacement slice returned by `realloc`.
- [`discarded-write-count`](discarded-write-count.md) — Reports a discarded
  partial-write count when `writeAll` is required for complete output.
- [`unchecked-first-element`](unchecked-first-element.md) — Reports a public
  function indexing a plain-slice parameter without a visible non-empty proof.
- [`unchecked-slice-reinterpretation`](unchecked-slice-reinterpretation.md) —
  Reports a plain slice reinterpreted as an aligned typed pointer.
- [`undefined-readvec-destination`](undefined-readvec-destination.md) — Reports
  `readVec` calls whose destination slice descriptors remain undefined.
- [`local-storage-escape`](local-storage-escape.md) — Reports a local array view
  retained through a callee beyond the array's safe lifetime.
- [`incomplete-owned-field-cleanup`](incomplete-owned-field-cleanup.md) —
  Reports cleanup that drops proven owned aggregate or container-element
  fields.
- [`partial-ownership-transfer`](partial-ownership-transfer.md) — Reports
  transfer of one owned field while the owner's remaining resources are dropped.
- [`stale-index-map`](stale-index-map.md) — Reports sequence removal without
  updating a sibling map or element field that stores sequence indices.
- [`lock-order-cycle`](lock-order-cycle.md) — Reports opposite nested lock
  acquisition orders across visible functions.
- [`wait-while-holding-lock`](wait-while-holding-lock.md) — Reports waiting for
  state while holding the lock required to signal it.
- [`silent-buffer-truncation`](silent-buffer-truncation.md) — Reports fixed-buffer
  writes that silently drop input beyond available capacity.
- [`pointer-only-free`](pointer-only-free.md) — Reports allocator frees whose
  allocation length was reconstructed from only a pointer.
- [`nullable-pointer-length`](nullable-pointer-length.md) — Reports nullable C
  pointers that can leave positive-length output uninitialized.
- [`discarded-resource`](discarded-resource.md) — Reports discarded OS handles
  returned by resource-acquiring calls.
- [`child-pipe-double-close`](child-pipe-double-close.md) — Reports a child pipe
  closed manually before a wait operation that also owns it.
- [`unwaited-child-process`](unwaited-child-process.md) — Reports a spawned
  child that leaves scope without wait, kill, or ownership transfer.
- [`overflow-before-clamp`](overflow-before-clamp.md) — Reports direct checked
  integer arithmetic that can overflow before `@min` or `@max` applies its bound.
- [`unchecked-range-end`](unchecked-range-end.md) — Reports runtime range-end
  addition that can overflow before a comparison validates the range.
- [`unsequenced-state-access`](unsequenced-state-access.md) — Reports aggregate
  literals that copy a mutable local in one field and advance it in another.
- [`quadratic-front-removal`](quadratic-front-removal.md) — Reports repeated
  `orderedRemove(0)` calls while draining an array list.
- [`aliased-memcpy`](aliased-memcpy.md) — Reports `@memcpy` source and
  destination slices derived from the same base value.
- [`usize-in-packed-struct`](usize-in-packed-struct.md) — Reports pointer-sized
  integer fields in packed or extern layouts.
- [`unconditional-busy-loop`](unconditional-busy-loop.md) — Reports
  `while (true)` bodies with no visible break, return, or call.
- [`padded-byte-compare`](padded-byte-compare.md) — Reports byte-wise comparison
  of values whose struct layout contains padding.
- [`useless-error-return`](useless-error-return.md) — Reports an error-returning
  function whose fully visible body cannot fail.
- [`exposed-private-type`](exposed-private-type.md) — Reports a public signature
  that names a private local type.
- [`exposed-private-error-set`](exposed-private-error-set.md) — Reports a public
  signature that names a private local error set.
- [`deprecated-declaration`](deprecated-declaration.md) — Reports use of a
  declaration marked `Deprecated:` in its doc comment.
- [`mutated-container-copy`](mutated-container-copy.md) — Reports mutation of a
  by-value container field copy that is not written back.

## Opt-in style and policy rules

- [`discarded-error`](discarded-error.md) — Reports an empty `catch {}` body.
- [`redundant-bool-comparison`](redundant-bool-comparison.md) — Reports a proven
  boolean compared with `true` or `false`.
- [`redundant-boolean-if`](redundant-boolean-if.md) — Reports an `if` expression
  whose branches merely return a boolean condition or its negation.
- [`non-exhaustive-switch-else`](non-exhaustive-switch-else.md) — Reports `else`
  used in a switch over a proven finite enum or tagged union when the remaining
  cases can be named.
- [`non-idiomatic-name`](non-idiomatic-name.md) — Reports declarations that do
  not follow Zig's function, type, or variable naming conventions.
- [`unsorted-imports`](unsorted-imports.md) — Reports a safely reorderable
  top-level import block that is not grouped and sorted by path.
- [`needless-cast`](needless-cast.md) — Reports nested identical casts or a cast
  whose operand is proven to already have the target type.
- [`needless-else-after-terminator`](needless-else-after-terminator.md) —
  Reports `else` after a branch that always returns, breaks, continues, or
  evaluates to `noreturn`.
- [`needless-empty-else`](needless-empty-else.md) — Reports an empty else
  branch.
- [`mixed-bitwise-arithmetic`](mixed-bitwise-arithmetic.md) — Reports bitwise
  and arithmetic operators mixed without explicit parentheses.
- [`unused-private-declaration`](unused-private-declaration.md) — Reports a
  private declaration that is never referenced in its file.
- [`unsafe-catch-unreachable`](unsafe-catch-unreachable.md) — Reports
  `catch unreachable` on an operation known to be fallible.
- [`lost-error-context`](lost-error-context.md) — Reports a catch that maps
  every failure to one replacement error without using the captured original
  error.
- [`unknown-comptime-member`](unknown-comptime-member.md) — Reports `@hasField`
  or `@hasDecl` checks that are always false for a resolved analyzed type shape.
- [`constant-comptime-condition`](constant-comptime-condition.md) — Reports an
  explicitly comptime condition that is the literal `true` or `false`.
- [`invariant-loop-condition`](invariant-loop-condition.md) — Reports a simple
  while condition fixed by a literal constant.
- [`vague-type-name`](vague-type-name.md) — Reports type names containing
  generic words that do not describe a domain role.
- [`redundant-qualified-name`](redundant-qualified-name.md) — Reports a nested
  type name that repeats its containing namespace.
- [`underscore-private-name`](underscore-private-name.md) — Reports declarations
  prefixed with `_` to suggest privacy.
- [`non-idiomatic-file-name`](non-idiomatic-file-name.md) — Reports a Zig source
  filename whose casing does not match the kind of declaration it represents.
- [`doc-comment-style`](doc-comment-style.md) — Reports a doc comment that
  merely repeats information already supplied by the declaration name.
- [`public-declaration-docs`](public-declaration-docs.md) — Reports a public
  declaration without a doc comment.
- [`prefer-optional-capture`](prefer-optional-capture.md) — Reports an optional
  checked for non-null and then force-unwrapped in the guarded branch.
- [`prefer-try`](prefer-try.md) — Reports a caught error that is immediately
  returned unchanged.
- [`prefer-testing-expect-equal`](prefer-testing-expect-equal.md) — Reports
  `std.testing.expect(actual == literal)`-style assertions.
- [`mutable-pointer-parameter`](mutable-pointer-parameter.md) — Reports a `*T`
  parameter whose pointee is only read.
- [`redundant-comptime`](redundant-comptime.md) — Reports an explicit `comptime`
  expression already inside a comptime scope.
- [`redundant-inline`](redundant-inline.md) — Reports `inline for` or
  `inline while` already inside a comptime scope.
- [`needless-defer-block`](needless-defer-block.md) — Reports a `defer` or
  `errdefer` block containing only one expression statement.
- [`non-exhaustive-error-switch`](non-exhaustive-error-switch.md) — Reports a
  switch over a known finite error set that does not name every error.
- [`duplicate-import`](duplicate-import.md) — Reports the same module path
  imported more than once in one file.
- [`unused-import`](unused-import.md) — Reports a private import alias that is
  never referenced.
- [`redundant-import-path`](redundant-import-path.md) — Reports a relative
  import path beginning with an unnecessary `./` segment.
- [`redundant-type-qualification`](redundant-type-qualification.md) — Reports a
  fully qualified enum value when the result location already establishes its
  type.
- [`prefer-anonymous-initializer`](prefer-anonymous-initializer.md) — Reports a
  named aggregate initializer that repeats a type already established by the
  result location.
- [`unsafe-orelse-unreachable`](unsafe-orelse-unreachable.md) — Reports
  `orelse unreachable` used to unwrap an optional.
- [`redundant-optional-unwrap`](redundant-optional-unwrap.md) — Reports
  force-unwrapping an optional inside a scope where its payload is already
  available as a capture.
- [`prefer-testing-expect-equal-strings`](prefer-testing-expect-equal-strings.md)
  — Reports byte-string equality assertions that use a generic boolean or
  equality check.
- [`error-collapsed-to-absence`](error-collapsed-to-absence.md) — Reports a
  catch that converts every error to `null` or another empty optional result.
- [`prefer-testing-expect-equal-slices`](prefer-testing-expect-equal-slices.md)
  — Reports manual slice comparison in a test assertion.
- [`prefer-testing-expect-error`](prefer-testing-expect-error.md) — Reports a
  manual catch-based assertion for one expected error.
- [`prefer-testing-expect-approx`](prefer-testing-expect-approx.md) — Reports a
  manual absolute-difference floating-point assertion.
- [`prefer-optional-presence-test`](prefer-optional-presence-test.md) — Reports
  an optional capture used only to test whether the optional is present.
- [`redundant-error-capture`](redundant-error-capture.md) — Reports a caught
  error capture that is never referenced.
- [`needless-switch-else-capture`](needless-switch-else-capture.md) — Reports an
  unused capture on a switch `else` prong.
- [`prefer-sentinel-termination`](prefer-sentinel-termination.md) — Reports
  manual allocation of an extra element followed by writing a zero terminator.
- [`duplicate-c-import`](duplicate-c-import.md) — Reports identical `@cImport`
  translation blocks in different project files.
- [`unreferenced-test-file`](unreferenced-test-file.md) — Reports a test source
  file that is neither imported by another Zig file nor referenced from
  `build.zig`.
- [`conflicting-build-options`](conflicting-build-options.md) — Reports one root
  source configured with different target or optimization options across compile
  units.
- [`inclusive-index-bound`](inclusive-index-bound.md) — Reports an inclusive
  `index <= len`-style assertion used before indexing that requires
  `index < len`.
- [`negated-comptime-expression`](negated-comptime-expression.md) — Reports
  `!comptime expression`, whose precedence is easy to misread.
- [`unbraced-multiline-if`](unbraced-multiline-if.md) — Reports an unbraced `if`
  whose single body statement begins on a later line.
- [`banned-identifier`](banned-identifier.md) — Reports use of a
  project-configured identifier or dotted path.
- [`truncating-intcast`](truncating-intcast.md) — Reports `@intCast` from a
  wider integer binding to a narrower target without a visible range guard.
- [`prefer-range-for`](prefer-range-for.md) — Reports exact counter loops that a
  range `for` expresses directly.
- [`prefer-index-of`](prefer-index-of.md) — Reports simple manual linear-search
  loops.
- [`prefer-memset`](prefer-memset.md) — Reports element loops that only fill a
  slice with one value.
- [`prefer-memcpy`](prefer-memcpy.md) — Reports element loops that only copy
  corresponding elements between distinct slices.
- [`prefer-expression-initializer`](prefer-expression-initializer.md) — Reports
  undefined locals assigned exactly once by every branch of an adjacent
  `if` or `switch`.
- [`combine-identical-switch-prongs`](combine-identical-switch-prongs.md) —
  Reports adjacent uncaptured switch prongs with identical bodies.
- [`prefer-optional-while-capture`](prefer-optional-while-capture.md) — Reports
  `while (true)` loops whose first statement unwraps an optional or breaks.
- [`prefer-loop-else`](prefer-loop-else.md) — Reports a flag used only to run
  fallback work when a loop does not break.
- [`prefer-orelse`](prefer-orelse.md) — Reports optional `if` expressions that
  return their capture unchanged or choose a fallback.
- [`prefer-starts-with`](prefer-starts-with.md) — Reports `indexOf(...) == 0`
  prefix tests.
- [`prefer-ends-with`](prefer-ends-with.md) — Reports guarded manual suffix
  comparisons.
- [`prefer-count-scalar`](prefer-count-scalar.md) — Reports loops that only
  count elements equal to one scalar.
- [`prefer-replace-scalar`](prefer-replace-scalar.md) — Reports loops that only
  replace elements equal to one scalar.
- [`prefer-multi-sequence-for`](prefer-multi-sequence-for.md) — Reports indexed
  pairing of sequences whose equal lengths were asserted.
- [`prefer-early-return`](prefer-early-return.md) — Reports an `if` whose
  `else` branch only returns and can serve as a guard clause.
- [`prefer-switch`](prefer-switch.md) — Reports integer, enum, or error equality
  dispatch expressed as a repeated if/else-if chain.
- [`prefer-string-switch`](prefer-string-switch.md) — Reports repeated string
  equality dispatch over one subject.
- [`prefer-log-over-print`](prefer-log-over-print.md) — Reports production
  `std.debug.print` calls that should use configurable logging.
- [`prefer-buffered-writer`](prefer-buffered-writer.md) — Reports unbuffered
  small writes inside a loop.
- [`prefer-arena`](prefer-arena.md) — Reports scopes whose allocations and
  scope-exit releases already have arena-shaped lifetimes.
- [`inconsistent-import-alias`](inconsistent-import-alias.md) — Reports a module
  alias that differs from the project majority.
- [`minority-naming-style`](minority-naming-style.md) — Reports declaration
  casing that differs from the project majority for its kind.
- [`inconsistent-parameter-vocabulary`](inconsistent-parameter-vocabulary.md) —
  Reports an outlier name for a frequently repeated parameter type.
- [`inconsistent-error-set-style`](inconsistent-error-set-style.md) — Reports an
  explicit or inferred public error set that differs from project convention.
- [`allocator-first-parameter`](allocator-first-parameter.md) — Reports an
  allocator parameter that is not first after optional `self`.
- [`comptime-parameter-order`](comptime-parameter-order.md) — Reports a comptime
  parameter following a runtime parameter.
- [`todo-comment`](todo-comment.md) — Reports configured task markers in line
  comments.
- [`assertion-free-test`](assertion-free-test.md) — Reports tests with no visible
  assertion or fallible expectation.
- [`line-length`](line-length.md) — Reports source lines over the configured
  display-column limit.

## Modernization profile

- [`modernize-managed-container`](modernize-managed-container.md) — Reports
  allocator-storing managed containers that should use current unmanaged APIs.
- [`modernize-deprecated-io`](modernize-deprecated-io.md) — Reports known
  pre-`std.Io` adapters and names their current replacement.
- [`modernize-deprecated-stdlib`](modernize-deprecated-stdlib.md) — Reports
  `std` declarations deprecated or removed in the pinned release and names the
  current replacement.

## Disciplined profile

- [`function-length`](function-length.md) — Reports functions longer than the
  disciplined source-line limit.
- [`assertion-free-branching`](assertion-free-branching.md) — Reports computed
  indexing without a visible statement of its invariant.
- [`unbounded-loop`](unbounded-loop.md) — Reports loops with no visible bound or
  exhaustion condition.
- [`allocation-after-init`](allocation-after-init.md) — Reports direct dynamic
  allocation outside recognized initialization paths.
- [`recursive-call`](recursive-call.md) — Reports direct and proven mutual
  recursion.
