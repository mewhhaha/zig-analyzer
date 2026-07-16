# `needless-defer-block`

[Rule index](RULES.md)

Reports a `defer` or `errdefer` block containing only one expression statement.

**Why it matters.** The direct form is shorter and makes the deferred operation
visible without an extra block.

**When it matters.** It applies only to a single expression whose block can be
removed without changing scope or declarations.
