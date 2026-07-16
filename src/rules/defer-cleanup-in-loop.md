# `defer-cleanup-in-loop`

[Rule index](RULES.md)

Reports cleanup deferred to a surrounding function scope from inside a loop.

**Why it matters.** Resources accumulate until the function returns instead of
being released at the end of each iteration.

**When it matters.** It applies when the defer is proven to outlive the loop
iteration, not to arbitrary defers inside a loop body scope.
