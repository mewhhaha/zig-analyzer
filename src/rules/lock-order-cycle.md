# `lock-order-cycle`

[Rule index](RULES.md)

Reports two functions that acquire the same pair of locks in opposite nested
orders.

**Why it matters.** Concurrent calls can each hold one lock while waiting for
the other, producing a deadlock.

**When it matters.** Both acquisition orders must be visible and use the same
receiver fields. Opaque or indirect lock calls are not inferred.
