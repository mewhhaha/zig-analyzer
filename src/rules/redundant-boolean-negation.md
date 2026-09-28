# `redundant-boolean-negation`

[Rule index](RULES.md)

Reports double boolean negation operations (`!!x` or `!(!x)`) and negated boolean constants (`!true` or `!false`).

**Why it matters.** In Zig, the `!` operator only accepts boolean values, so double negation is always a no-op that produces the original boolean value. Negating literal `true` or `false` is always equivalent to using the opposite constant directly. In languages like C or JavaScript, `!!x` is used to cast integers or pointers to booleans, but in Zig that idiom is invalid or redundant.

**When it matters.** It applies to double boolean negation expressions and negated boolean constants, offering a quickfix to use the simplified operand directly.
