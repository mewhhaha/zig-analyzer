# Proposed rules

This document describes rules that do not exist yet. Each entry is written to
the same standard as an implemented rule page: what it reports, why it
matters, and when it applies. The goal of the whole batch is the same: the
analyzer should not only reject wrong programs but teach the reader a better
program, the way a patient reviewer would.

The proposals come from three sources, gathered in a survey of every active
Zig lint tool (zlint, rockorager/ziglint, KurtWagner/zlinter, zwanzig,
AnnikaCodes/ziglint) plus ZLS, the compiler's own checks, and the TigerBeetle
and official style guides:

1. Rules other tools have that fit this architecture, usually with a stronger
   proof than the original because the compiler backend can resolve types.
2. Rules nobody has that turn recurring review feedback into diagnostics —
   the "helping hand" family.
3. Rules that recognize a project's own patterns and teach consistency with
   them instead of a fixed policy.

A proposal graduates by following [EXTENDING.md](EXTENDING.md): enum member,
tier, module, registry entry, tests, and a rule page linked from
[RULES.md](src/rules/RULES.md). Until then it must not appear in the rule
index; the reference test counts implemented rules exactly.

## Summary

| Rule | Group | Suggested tier |
| --- | --- | --- |
| `useless-error-return` | Compiler-proven hygiene | correctness warning |
| `exposed-private-type` | Compiler-proven hygiene | correctness warning |
| `exposed-private-error-set` | Compiler-proven hygiene | correctness warning |
| `deprecated-declaration` | Compiler-proven hygiene | correctness warning |
| `mutated-container-copy` | Compiler-proven hygiene | correctness warning |
| `prefer-range-for` | Helping hand | opt-in style |
| `prefer-index-of` | Helping hand | opt-in style |
| `prefer-memset` | Helping hand | opt-in style |
| `prefer-memcpy` | Helping hand | opt-in style |
| `prefer-string-switch` | Helping hand | opt-in style |
| `prefer-log-over-print` | Helping hand | opt-in style |
| `prefer-buffered-writer` | Helping hand | opt-in style |
| `prefer-arena` | Helping hand | opt-in style |
| `inconsistent-import-alias` | Project consistency | opt-in style |
| `minority-naming-style` | Project consistency | opt-in style |
| `inconsistent-parameter-vocabulary` | Project consistency | opt-in style |
| `inconsistent-error-set-style` | Project consistency | opt-in style |
| `modernize-managed-container` | Modernization | `modernize` profile |
| `modernize-deprecated-io` | Modernization | `modernize` profile |
| `function-length` | Discipline profile | `disciplined` profile |
| `assertion-free-branching` | Discipline profile | `disciplined` profile |
| `unbounded-loop` | Discipline profile | `disciplined` profile |
| `allocation-after-init` | Discipline profile | `disciplined` profile |
| `recursive-call` | Discipline profile | `disciplined` profile |
| `line-length` | Policy | opt-in style |
| `allocator-first-parameter` | Policy | opt-in style |
| `comptime-parameter-order` | Policy | opt-in style |
| `todo-comment` | Policy | opt-in style |
| `assertion-free-test` | Policy | opt-in style |

## Prerequisites: hardening before growing

Two false-positive classes showed up when running `check` against real
projects (libxev, zap). They are fixes to existing rules, not new rules, but
they gate the credibility of everything below and should land first.

- **`non-idiomatic-name` must exempt foreign-ABI declarations.** On libxev it
  reported 253 findings, mostly `extern` bindings like `CreateIoCompletionPort`
  and `GENERIC_READ` whose names are dictated by the foreign symbol. The
  official style guide exempts names that bind an external API. Skip `extern`
  declarations, declarations initialized from `@extern`, and constants whose
  initializer is a literal in a file dominated by such bindings.
- **File-local rules must not fire on generated sources.** On zap,
  `never-mutated-var` reported ~40 findings inside `src/deps/cimport.zig`, a
  `translate-c` output. `check.exclude` already exists, but the scanner should
  recognize translate-c preambles (a leading run of
  `pub const __builtin_… = @import("std").zig.c_builtins.…` re-exports) and
  skip such files by default, reporting one note that the file was skipped.

## Compiler-proven hygiene

These rules need resolved types or project reachability. Other tools
approximate them from syntax; the backend can prove them, which is the
difference between a suggestion the user trusts and one they learn to ignore.

### `useless-error-return`

Reports a function whose return type is an error union although no statement
in its body can return or propagate an error.

**Why it matters.** A false error union taxes every caller forever: each call
site must `try`, `catch`, or `switch` on errors that cannot happen, and the
reader is told a lie about which operations can fail. Removing it simplifies
the whole call tree, and the diagnostic teaches that error sets are part of a
function's documented contract, not a default to reach for.

**When it matters.** It applies when the body is fully analyzed and contains
no `return error…`, no `try`, no `catch`-free call returning an error union,
and no errorable builtin. Functions that are exported, override a declared
function-pointer type, or satisfy a comptime interface shape are exempt, since
their signature is constrained elsewhere. The fix — rewriting the return type
and relaxing call sites in open files — changes public API, so it is an
explicit action, never fix-all.

```zig
fn parseFlagName(arg: []const u8) ![]const u8 {   // ! is unearned
    if (std.mem.startsWith(u8, arg, "--")) return arg[2..];
    return arg;
}
```

Provenance: zlint `useless-error-return`, upgraded from a syntactic guess to a
semantic proof.

### `exposed-private-type`

Reports a public declaration whose signature mentions a type that is not
reachable from outside the file.

**Why it matters.** A caller in another file can obtain the value but cannot
name its type, so it cannot store it in a struct field, put it in a container,
or write the type in its own signatures. The author usually never notices
because their own tests live in the same file. The diagnostic teaches that
`pub` is transitive: publishing a function publishes its whole signature.

**When it matters.** It applies when a `pub` function, constant, or field type
resolves to a container declared without `pub` in the same file, including
through pointers, optionals, slices, and error-union payloads. Returning a
private type from a private function is fine and stays silent.

Provenance: rockorager/ziglint Z012, with resolution through type constructors
the syntactic version cannot follow.

### `exposed-private-error-set`

Reports a public function whose inferred or named error set contains errors
from a non-`pub` error set declaration.

**Why it matters.** Callers can `catch |err|` the value but cannot write an
exhaustive `switch` naming the set, and cannot mention the set in their own
return types. The error contract is published but unnameable — the same lesson
as `exposed-private-type`, applied to the error channel.

**When it matters.** It applies when the resolved error set of a `pub`
function's return type includes a member of a named, non-`pub` error set
declared in the file. Anonymous inline sets (`error{OutOfMemory}`) are exempt;
they are structural and every caller can respell them.

Provenance: rockorager/ziglint Z015.

### `deprecated-declaration`

Reports a reference to a declaration whose doc comment begins with
`Deprecated:`, the convention the standard library uses.

**Why it matters.** Deprecations in Zig are prose; nothing warns until the
declaration is deleted a release later and the build breaks. Surfacing the doc
comment's own migration text at every use site turns each upgrade into a
guided, incremental migration instead of a flag day. This is the single most
"learning tool" rule in the batch: the message quotes the library author's own
advice at exactly the moment it applies.

**When it matters.** It applies when the resolved target of an identifier,
member access, or call has a doc comment whose first word is `Deprecated:`
(case-insensitive, after `///` trimming), in any module including the standard
library. The message includes the rest of that first line verbatim. When the
comment names a drop-in replacement and the replacement's signature matches,
the rule offers the rename as a safe fix; otherwise it stays a diagnostic.

Provenance: rockorager/ziglint Z011 and zlinter `no_deprecated`; the backend
makes it work across module boundaries.

### `mutated-container-copy`

Reports mutation of a by-value copy of a container when the mutation is
visible only to the copy.

**Why it matters.** `var list = self.list;` copies an `ArrayList` struct: the
pointer, length, and capacity. Appending to the copy may reallocate, at which
point the original silently keeps the stale buffer and the appended elements
leak with the copy. This is one of the most common value-semantics surprises
for people arriving from reference-semantics languages, and the diagnostic can
say precisely that: "this mutates a copy; the original `self.list` will not
see it."

**When it matters.** It applies when a local `var` is initialized by copying a
container value (a type with an internal pointer-and-capacity shape) from a
field or pointer dereference, the copy is mutated through a method that can
reallocate or change length, and the copy is neither written back nor
returned. Copies that are written back (`self.list = list;`) or intentionally
drained are silent.

Provenance: zlint `must-return-ref` inspired the direction; this formulation
targets the actual defect rather than banning by-value returns.

## Helping hand: recognize the pattern, teach the idiom

Each rule in this family recognizes a working but manual pattern and suggests
the idiomatic equivalent, with a provably equivalent rewrite where the syntax
permits one. They are the answer to "how would an experienced Zig programmer
write this?" and they all belong in the opt-in style tier, enabled by the
`idiomatic` profile.

The family shares a design rule: **only fire on exact shapes.** A suggestion
that is right 80% of the time is a rule users disable. Every entry below
states the shape it matches; anything else stays silent.

### `prefer-range-for`

Reports a counter `while` loop that a range `for` expresses directly.

**Why it matters.** `for (0..n) |i|` states the iteration space in one place;
the `while` form spreads it across an init, a condition, and a continue
expression that must be checked against each other for off-by-one drift. The
`for` form also makes the index immutable, removing a class of accidental
mutation.

**When it matters.** It applies to
`var i: usize = 0; while (i < n) : (i += 1)` where the counter starts at a
constant, the bound is loop-invariant, the step is `+= 1`, the body never
assigns the counter, and the counter is dead after the loop. The rewrite to
`for (0..n) |i|` is semantics-preserving under those proofs and safe for
fix-all. Loops that mutate the counter, use a non-unit step, or read it after
exit are silent — those are what `while` is for.

```zig
var i: usize = 0;                 // three places to get wrong
while (i < names.len) : (i += 1) {
    try greet(names[i]);
}

for (0..names.len) |i| {          // one
    try greet(names[i]);
}
```

### `prefer-index-of`

Reports a manual linear-search loop over a slice that
`std.mem.indexOfScalar`, `std.mem.indexOf`, or `std.mem.lastIndexOfScalar`
replaces.

**Why it matters.** The named function states intent — "find this" — where
the loop makes the reader reconstruct it from a counter, a comparison, and a
break. It also centralizes the boundary conditions the manual version gets
wrong on the last element or the empty slice.

**When it matters.** It applies to a loop whose body only compares one element
against a loop-invariant needle and breaks (or returns) with the index on
match. The rewrite carries the found/not-found distinction through the
function's optional return, so the surrounding `if` shape is preserved.
Searches with side effects, multiple needles, or early transforms are silent.

### `prefer-memset`

Reports an element loop that assigns the same loop-invariant value to every
element of a slice.

**Why it matters.** `@memset(buffer, 0)` is one token of intent and lets the
compiler pick the fastest fill; the loop buries "fill" in iteration machinery
that must be read element by element to confirm nothing else happens.

**When it matters.** It applies when the loop covers the whole slice and the
body is a single index-store of a loop-invariant value. Partial fills rewrite
to `@memset(buffer[a..b], v)` only when the bounds are the loop's own bounds.
Anything else in the body silences the rule.

### `prefer-memcpy`

Reports an element loop that copies corresponding elements between two slices
that provably do not alias.

**Why it matters.** Same lesson as `prefer-memset`: name the operation. And
`@memcpy` asserts equal lengths, converting a silent partial copy into a
caught error during development.

**When it matters.** It applies when the body is a single
`dst[i] = src[i]`-shaped store over the full common range and the slices
derive from distinct bases (the aliasing proof already exists for
`aliased-memcpy`, reused in the opposite direction). Overlapping or
conditionally-copying loops are silent; the message mentions
`std.mem.copyForwards` when aliasing cannot be excluded but the shape
otherwise matches.

### `prefer-string-switch`

Reports an `if`/`else if` chain of `std.mem.eql(u8, s, "…")` comparisons
against string literals.

**Why it matters.** The chain is O(chain length) scans of the same string and
hides the real structure: a dispatch on a closed set of names. The idiomatic
forms make the set explicit — `std.meta.stringToEnum` when the names map onto
an enum, `std.StaticStringMap` when they map onto values — and both get a
proper `else`/null arm for free, where chains routinely forget the final
`else`.

**When it matters.** It applies to three or more `else if` arms all comparing
the same subject against distinct literals. When an enum with matching field
names is in scope the fix rewrites to `stringToEnum` plus `switch`; otherwise
the message shows the `StaticStringMap` shape without offering an automatic
edit, since choosing value types is design, not mechanics.

```zig
if (std.mem.eql(u8, cmd, "start")) { … }
else if (std.mem.eql(u8, cmd, "stop")) { … }
else if (std.mem.eql(u8, cmd, "status")) { … }

switch (std.meta.stringToEnum(Command, cmd) orelse return error.UnknownCommand) {
    .start => { … },
    .stop => { … },
    .status => { … },
}
```

### `prefer-log-over-print`

Reports `std.debug.print` in library and application code outside tests and
`build.zig`.

**Why it matters.** `std.debug.print` writes to stderr unconditionally: no
level, no scope, no way for the embedding application to silence or reroute
it. `std.log` gives the *user* of the code those controls. The rule teaches
the difference between debugging output (yours, temporary) and diagnostics
(the program's, configurable) — a distinction most people meet for the first
time when a dependency spams their stderr.

**When it matters.** It applies outside `test` blocks, test-only files, and
build scripts. CLI programs that print to stdout as their actual output use
`std.fs.File.stdout()` writers, not `debug.print`, so genuine program output
does not trigger it. The fix maps to `std.log.debug` and preserves the format
string; it is offered per-site, not fix-all, because choosing the level is a
judgment call. Provenance: zlint `no-print`, with the test/build carve-outs
that make it enableable.

### `prefer-buffered-writer`

Reports repeated small writes to an unbuffered file or stream writer inside a
loop.

**Why it matters.** Each write is a syscall; a loop of them is the classic
order-of-magnitude I/O slowdown that profilers find and reviewers catch on
sight. Wrapping the writer in a buffer and flushing once is the standard cure,
and pointing it out with the loop in view teaches the habit better than any
profiling session.

**When it matters.** It applies when a writer obtained directly from a file,
socket, or stdout reaches `print`/`write` calls inside a loop without an
intervening buffering wrapper, with the writer's provenance resolved by the
backend (the same allocator-style provenance the ownership engine already
tracks). Writers passed in as parameters are silent — the caller may already
buffer; the boundary owns that decision.

### `prefer-arena`

Reports a scope that performs several allocations from the same
general-purpose allocator and releases every one of them at scope exit.

**Why it matters.** That shape *is* an arena: allocate freely, free once. The
rewrite deletes every individual `defer`/`errdefer` (each a leak opportunity —
several rules in this analyzer exist purely to catch mistakes in them) and
replaces bookkeeping with a structural guarantee. Teaching arenas at the
moment a function visibly wants one is worth more than any documentation page,
because it converts the reader's own code into the example.

**When it matters.** It applies when a scope makes three or more allocations
from one allocator binding, each has a matching scope-exit release (proven by
the existing allocation-lifecycle engine), and none of the allocations escape
the scope. The message sketches the `std.heap.ArenaAllocator` form; no
automatic fix, since lifetimes are design. Scopes where any allocation
escapes, or where releases happen mid-scope to bound memory, are silent —
those are exactly the cases where an arena is wrong.

## Project consistency: learn the codebase, then teach it

Nothing in the ecosystem does this. These rules do not encode a style; they
detect the project's dominant convention from the project scanner's corpus and
flag the minority spellings. The message always names the local evidence —
"87 of 91 functions in this project are camelCase" — so the finding reads as
the codebase teaching itself. All of these live in `src/rules/project.zig`
territory: they must see the whole scanned project, never one file.

Shared design rules: a convention only counts as dominant above a high
threshold (e.g. ≥90% of at least 20 samples), generated and foreign-ABI
declarations are excluded from both counting and flagging, and the rules stay
information severity — consistency is advice, not an error.

### `inconsistent-import-alias`

Reports a module imported under a different alias than the one the rest of
the project uses.

**Why it matters.** When `@import("sqlite")` is `sqlite` in nine files and
`db` in the tenth, every cross-file reader pays a renaming tax, and
project-wide search silently misses the outlier. One module, one name is the
cheapest consistency win a codebase can buy.

**When it matters.** It applies when the same resolved module path is bound to
different top-level alias names across files and one alias holds the clear
majority. The fix renames the minority alias file-locally — safe, mechanical,
and fix-all eligible since the alias is file-scoped by construction.

### `minority-naming-style`

Reports a declaration whose naming style deviates from the project's own
dominant convention for that declaration kind.

**Why it matters.** `non-idiomatic-name` enforces the official style guide;
this rule enforces the project against itself, which matters for the many
codebases that deviate deliberately (TigerBeetle uses snake_case functions
project-wide). Mixed styles inside one project are worse than either style:
they make every call site a small spelling quiz. The pairing also fixes a real
adoption problem observed on libxev: a project that has chosen snake_case
functions gets hundreds of official-style findings it will never act on, but
would act on the handful of names that break *its own* pattern.

**When it matters.** It applies per declaration kind (function, type,
constant) when a dominant project style exists and the declaration deviates
from it. When the project's dominant style itself deviates from the official
guide, enabling this rule automatically quiets `non-idiomatic-name` for that
kind — the two rules must never both fire on the same name in opposite
directions.

### `inconsistent-parameter-vocabulary`

Reports a parameter whose name diverges from the project's dominant name for
parameters of the same resolved type.

**Why it matters.** When 40 functions take `allocator: std.mem.Allocator` and
two take `a:` and `alloc:`, the odd names are friction at every call site and
in every grep. Same concept, same word is the vocabulary rule reviewers
enforce by hand today; the type resolution makes it mechanical. Allocators,
writers, and readers are where this bites hardest in Zig, and they are all
resolvable types.

**When it matters.** It applies to parameters of a small set of
high-traffic resolved types (allocator, writer/reader interfaces, and the
project's own most frequent parameter types) when one name holds a
super-majority. The fix renames the parameter and its uses within the
function — local, safe, fix-all eligible.

### `inconsistent-error-set-style`

Reports a public function using an inferred error set (`!T`) in a project
that writes explicit error sets on its public functions, or the reverse.

**Why it matters.** Explicit versus inferred error sets is a legitimate
project-level choice — explicit sets document and stabilize the API surface,
inferred sets reduce ceremony — but a mix delivers neither benefit: callers
cannot rely on stability and still pay the ceremony where it exists. The
message explains what each style buys, so the finding doubles as the best
short lesson on error-set design the user will encounter in an editor.

**When it matters.** It applies to `pub` functions only, when the project has
a dominant style among its public error-returning functions. The existing
explicit-error-set code action performs the inferred→explicit direction;
this rule decides *when* to surface it, and stays silent in projects with no
established preference.

## Modernization: move code forward a release

Zig's release cadence renames and reshapes standard-library idioms, and the
ecosystem's recurring pain is mechanical migration. No existing tool owns
this. A `modernize` profile — off by default, one command in release notes:
`zig-analyzer check --fix` with the profile enabled — would make this analyzer
the upgrade tool for its pinned release. `deprecated-declaration` above is the
generic engine; these rules add rewrites where the fix is provable rather than
merely locatable.

### `modernize-managed-container`

Reports use of the deprecated managed container variants
(`std.array_list.Managed` and relatives) and rewrites to the unmanaged form
with an explicit allocator argument.

**Why it matters.** The standard library moved to allocator-per-call
containers; the managed forms exist as a migration shim and will be removed.
Beyond mechanics, the migration carries the release's actual lesson: storing
the allocator per-container hid a dependency that call sites now state — the
reader of `list.append(allocator, x)` knows the call can allocate.

**When it matters.** It applies when a binding's type resolves to a managed
container variant. The rewrite changes the declaration and threads the
allocator into each method call in the binding's scope, using the allocator
the managed container was constructed with — resolvable by the same
provenance tracking the lifecycle engine uses. When the constructing allocator
cannot be resolved, the rule reports without a fix.

### `modernize-deprecated-io`

Reports use of the pre-`std.Io` reader/writer adapters and points to the
current interface.

**Why it matters.** The I/O interface rework is the largest std migration in
recent releases, and the old adapters are deprecation-doc-commented shims.
Every message carries the specific replacement for the specific adapter used,
so a codebase can migrate call by call instead of reading a release-notes
essay and grepping.

**When it matters.** It applies when a resolved call target is one of the
known adapter shims. Rewrites are offered only for the one-to-one renames;
shape changes (buffer ownership moving to the caller) report with the target
API named but no automatic edit.

## Discipline profile: TigerStyle as an opt-in

TigerBeetle's TIGER_STYLE is the most cited engineering-discipline document in
the Zig community, and several of its rules are mechanically checkable. A
built-in `disciplined` profile — all off by default, enabled as a set —
gives that audience a reason to adopt the analyzer, and gives everyone else a
graded path: the messages explain the safety reasoning, which is the teaching
payload even for projects that never enable the profile.

### `function-length`

Reports a function body longer than a configured line limit (default 70).

**Why it matters.** The limit is a forcing function for decomposition: a
function that cannot fit in one screen cannot be reviewed in one reading.
TigerStyle's argument — hard limits convert "should refactor sometime" into
"must decide now" — is stated in the message.

**When it matters.** It applies to function declarations whose body spans more
than the limit in source lines, counting comments and blank lines (the reader
scrolls past those too). Test blocks and comptime-generated bodies are exempt.
Configurable via a rule setting; no fix.

### `assertion-free-branching`

Reports a function that indexes, does pointer arithmetic, or branches on
numeric ranges but contains no assertion of its assumptions.

**Why it matters.** TigerStyle asks for two assertions per function on
average. A per-function average is not a lint, but the underlying claim is
checkable: code that computes with invariants should state them. Assertions
document the argument for correctness in a form the Debug build checks, and a
function slicing `buf[start..end]` with no stated relation between `start`,
`end`, and `buf.len` is one refactor away from a safety-check crash whose
cause is far from its symptom.

**When it matters.** It applies to functions above a small size threshold
whose bodies index or slice with computed operands and contain no
`std.debug.assert`, no `unreachable` arm, and no early-return validation of
those operands. The message names the unchecked computation, not just the
count. This is the most heuristic rule in the batch and belongs at the bottom
of the profile's severity list.

### `unbounded-loop`

Reports a loop with no statically evident iteration bound.

**Why it matters.** TigerStyle bans unbounded loops because a loop with no
bound has no worst case: it converts a corrupted length field or a
never-arriving event into a hang instead of a crash with a backtrace. The
discipline is to state the bound (`for (0..max_attempts)`) and handle bound
exhaustion explicitly.

**When it matters.** It applies to `while` loops whose condition does not
compare against a loop-invariant bound and whose body contains no counter
guard, excluding the accepted top-level shapes (an event loop's
`while (true)` around a blocking dispatch is recognized and exempted — the
related `unconditional-busy-loop` rule already identifies the pathological
subset). Iterator loops (`while (it.next()) |x|`) are bounded by construction
and silent.

### `allocation-after-init`

Reports dynamic allocation reachable from outside a type's initialization
paths.

**Why it matters.** TigerStyle's "allocate at startup, never after" removes
out-of-memory as a runtime failure mode: all allocation failures happen at
init, where they are reportable and recoverable. For long-running services
this single discipline eliminates the hardest-to-test error paths in the
program — every mid-flight `error.OutOfMemory` branch.

**When it matters.** It applies when a method other than recognized init
shapes (`init`, `create`, names configured per project) transitively performs
allocator calls, using the project scanner's call graph approximation. Types
that are themselves allocators or containers are exempt. This is a
whole-project rule with an inherently approximate call graph; it reports
direct allocations first and widens only as the graph proves reliable.

### `recursive-call`

Reports direct or mutual recursion.

**Why it matters.** Recursion depth is a hidden, input-controlled stack
allocation; TigerStyle requires all execution to be bounded, and the stack is
the resource people forget to bound. The rewrite to an explicit worklist makes
the memory cost visible and bounds it with the container.

**When it matters.** It applies when a function's body can reach itself:
directly, or through the project call graph for mutual cycles. `inline`
recursion that comptime provably terminates is exempt. The message names the
cycle (`a → b → a`), because mutual recursion is the case the author does not
already know about.

## Policy and ergonomics

Small rules with configurable thresholds. Individually minor; collectively
they close the "table stakes" gap with other tools, and each still carries a
one-sentence lesson.

### `line-length`

Reports lines longer than a configured limit (default 100 columns).

**Why it matters.** `zig fmt` wraps what it can but never enforces a column
limit, so long string literals, comments, and deeply chained expressions grow
unbounded. Three of the five other active Zig linters implement this; it is
the most requested trivial rule and its absence reads as a gap. The measure is display
columns, not bytes, so multibyte text does not false-positive.

**When it matters.** It applies to any source line above the limit, with a
configurable exemption for lines whose overflow is a single unsplittable token
(URLs in comments, test names). Off by default even in the `idiomatic`
profile; strictly a project policy.

### `allocator-first-parameter`

Reports a function that takes an allocator anywhere but the first parameter
position (after `self`).

**Why it matters.** The standard library's convention is allocator-first, and
call sites read fastest when the resource parameters land in a predictable
slot. Following std's parameter grammar is the cheapest way for an API to
feel native.

**When it matters.** It applies to functions with a `std.mem.Allocator`
parameter not in the first position after an optional self parameter.
Callback typedefs and functions matching an external signature are exempt.
Provenance: zlint `allocator-first-param`.

### `comptime-parameter-order`

Reports runtime parameters preceding `comptime` parameters.

**Why it matters.** Comptime parameters are the function's configuration;
runtime parameters are its input. The convention — configuration first —
groups the call site's constant part together and matches the dominant
standard-library shape, which puts comptime type parameters first.
Predictable parameter grammar is the lesson, same as allocator-first.

**When it matters.** It applies when a `comptime` parameter follows a
non-comptime one and no external signature constrains the order. Provenance:
rockorager/ziglint Z023.

### `todo-comment`

Reports comments containing configured task markers (`TODO`, `FIXME`, `XXX`
by default) — as an inventory, not a ban.

**Why it matters.** Markers are promises, and promises rot when they are only
visible in the file they were made in. Surfacing them through `check` puts the
inventory in CI output where it can be counted and trended. Projects that
treat TODOs as tickets can set the severity up and make merges honest.

**When it matters.** It applies to comment text matching a configured marker
list, skipping generated files. Off unless configured; the default marker list
is a starting point, and an issue-link requirement
(`TODO(#123)` passes, bare `TODO` reports) is a natural setting. Provenance:
zlinter `no_todo`, AnnikaCodes `banned_comment_phrases`, generalized.

### `assertion-free-test`

Reports a `test` block containing no assertion of any kind.

**Why it matters.** A test that asserts nothing passes when the code is wrong;
it verifies only "does not crash", usually by accident rather than intent. The
common causes are a commented-out expectation left behind or a test written as
a scratchpad. Making "every test states what it checks" mechanical closes the
gap between coverage and verification — and the finding teaches the habit at
the exact block that lacks it.

**When it matters.** It applies to `test` blocks whose bodies transitively
contain no `std.testing.*` expectation, no `try`/`catch` on a fallible call
(propagating an error *is* the assertion in error-path tests), and no
`std.debug.assert`. Crash-only tests that intentionally exercise
does-not-crash behavior can state it with a trailing
`comptime {}`-style marker or a suppression, which documents the intent —
which is the point.

## What deliberately did not make the list

- **Shadowing, unused locals, unused parameters, `var` that could be
  `const` in analyzed code** — the compiler hard-errors on all of these;
  duplicating them adds noise, not signal. (`never-mutated-var` exists here
  only because lazy analysis skips unreferenced bodies.)
- **`zig fmt` conformance** — formatting is already served byte-for-byte over
  LSP; a check-mode conformance flag is CLI plumbing, not a rule.
- **Blanket `undefined` bans** (zlint `unsafe-undefined`, zlinter
  `no_unsafe_undefined`) — `undefined-value-escape` already reports the actual
  defect (reading it) instead of the honest and idiomatic declaration.
- **`deinit` must poison `self.* = undefined`** (rockorager Z030) — present
  here as the "Poison after deinit" code action, which is the right shape: an
  offer, not a demand.
- **Average assertion density, abbreviated-name detection, banned `usize`**
  (TigerStyle) — not mechanically decidable without a false-positive rate
  that would poison the whole profile. `assertion-free-branching` above is
  the checkable core of the assertion rule.
