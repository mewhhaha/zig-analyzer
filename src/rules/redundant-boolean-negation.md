# `redundant-boolean-negation`

[Rule index](RULES.md)

Reports double boolean negation operations (`!!x` or `!(!x)`).

**Why it matters.** In Zig, the `!` operator only accepts boolean values, so double negation is always a no-op that produces the original boolean value. In languages like C or JavaScript, `!!x` is used to cast integers or pointers to booleans, but in Zig that idiom is invalid or redundant.

**When it matters.** It applies to double boolean negation expressions, offering a quickfix to use the un-negated operand directly.
