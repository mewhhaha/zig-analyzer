# `identical-comparison-operands`

[Rule index](RULES.md)

Reports a comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`) where both operands are textually and semantically identical paths.

**Why it matters.** Comparing an expression to itself (such as `x == x` or `left.len == left.len`) usually indicates a copy-paste error. Floating-point NaN is an exception: `x == x` is false and `x != x` is true for NaN. Use `std.math.isNan` to state that intent directly.

**When it matters.** It applies to comparisons of pure identifier and dotted field paths with identical structure and names.
