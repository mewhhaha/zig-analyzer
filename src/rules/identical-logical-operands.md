# identical-logical-operands

Reports a logical `and` or `or` expression whose left-hand and right-hand operands evaluate to the exact same path.

**Why it matters.** Logical operations with identical operands evaluate the same condition twice. In boolean logic, `x and x` is equivalent to `x`, and `x or x` is equivalent to `x`. Repeating the identical operand indicates either redundant evaluation or a typo where a different condition was intended.

**When it matters.** Always. Redundant boolean conjunctions or disjunctions almost always represent copy-paste bugs.
