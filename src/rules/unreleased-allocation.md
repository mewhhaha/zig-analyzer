# `unreleased-allocation`

[Rule index](RULES.md)

Reports a mechanically identified allocation with no visible matching release or
ownership return before scope exit.

**Why it matters.** Repeated execution leaks memory; an `errdefer`-only cleanup
still leaks on successful returns.

The rule also reports a failed `realloc` path that returns a newly allocated
replacement without releasing the still-valid original allocation.

**When it matters.** It tracks simple allocator bindings across local blocks,
`if`/`else` branches, exhaustive `switch` branches, `while` and `for` loops,
loop `else` branches, early returns, ownership returns, and propagated errors
covered by `errdefer`. Local binding and aggregate moves are followed until the
destination is released or transferred. Direct calls to resolvable helpers are
followed when the matching parameter is provably only borrowed or unconditionally
released before any visible exit; indirect calls, optional captures,
reallocations, cross-nested labeled exits, and other ambiguous constructs retain
the conservative lexical analysis.
Allocator fields and function parameters declared under the
`contracts.arena-allocators` project setting inherit the surrounding arena
lifetime and do not require individual releases.
Functions documenting that their allocator should be an arena provide the same
lifetime proof, including for private helpers that receive that parameter.
