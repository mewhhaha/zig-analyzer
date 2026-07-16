# `missing-struct-field`

[Rule index](RULES.md)

Reports a struct initializer that omits required fields without defaults.

**Why it matters.** An incomplete initializer cannot construct the promised
value and often indicates that a type change was not propagated to its callers.

**When it matters.** It applies only when the result type and required field set
are proven; anonymous or unresolved initializers are not guessed.
