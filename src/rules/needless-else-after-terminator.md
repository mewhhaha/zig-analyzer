# `needless-else-after-terminator`

[Rule index](RULES.md)

Reports `else` after a branch that always returns, breaks, continues, or
evaluates to `noreturn`.

**Why it matters.** Removing the else keeps the remaining happy path at the
outer indentation level without changing reachability.

**When it matters.** It applies only when termination of the preceding branch is
syntactically proven.
