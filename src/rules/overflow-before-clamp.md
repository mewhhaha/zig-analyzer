# `overflow-before-clamp`

[Rule index](RULES.md)

Reports direct checked integer addition inside `@min`, or subtraction inside
`@max`, when the arithmetic can overflow or underflow before the clamp is
evaluated.

**Why it matters.** Zig evaluates the arithmetic argument before calling the
clamp builtin. A bound such as `@min(limit, offset + amount)` therefore does not
prevent `offset + amount` from trapping.

**When it matters.** The rule requires two runtime-derived operands with locally
visible integer types. This excludes small literal lookaheads into already
materialized collections. Saturating or wrapping operators, checked arithmetic
APIs, and a visible early-exit guard keep the expression clean.
