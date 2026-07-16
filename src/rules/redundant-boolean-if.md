# `redundant-boolean-if`

[Rule index](RULES.md)

Reports an `if` expression whose branches merely return a boolean condition or
its negation.

**Why it matters.** The conditional duplicates logic already represented by the
condition and obscures the value being computed.

**When it matters.** It applies to simple boolean-producing branches that can be
replaced without changing evaluation or control flow.
