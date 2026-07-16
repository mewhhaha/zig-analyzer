# `negated-comptime-expression`

[Rule index](RULES.md)

Reports `!comptime expression`, whose precedence is easy to misread.

**Why it matters.** Hoisting negation inside the comptime expression makes both
evaluation timing and boolean grouping explicit.

**When it matters.** It applies to direct negation adjacent to `comptime`; the
suggested form preserves the intended expression.
