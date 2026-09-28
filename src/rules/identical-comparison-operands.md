# `identical-comparison-operands`

[Rule index](RULES.md)

Reports a comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`) where both operands are textually and semantically identical paths.

**Why it matters.** Comparing an expression to itself (such as `x == x` or `left.len == left.len`) always evaluates to a constant value and almost always represents a bug or copy-paste error. If checking a floating-point value for NaN, use `std.math.isNan` or `@isnan` instead of `x != x`.

**When it matters.** It applies to comparisons of pure identifier and dotted field paths with identical structure and names.
