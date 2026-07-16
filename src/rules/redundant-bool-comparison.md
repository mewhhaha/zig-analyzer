# `redundant-bool-comparison`

[Rule index](RULES.md)

Reports a proven boolean compared with `true` or `false`.

**Why it matters.** Using the boolean or its negation directly is shorter and
makes the condition's intent easier to scan.

**When it matters.** It applies only when the operand is known to be `bool`,
avoiding rewrites of user-defined comparison semantics.
