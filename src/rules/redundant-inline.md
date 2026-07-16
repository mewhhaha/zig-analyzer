# `redundant-inline`

[Rule index](RULES.md)

Reports `inline for` or `inline while` already inside a comptime scope.

**Why it matters.** The loop is already compile-time evaluated, so `inline`
repeats a guarantee supplied by the context.

**When it matters.** It applies to loops lexically contained by a proven
comptime block.
