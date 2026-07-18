# `prefer-count-scalar`

[Rule index](RULES.md)

Reports a loop that increments one counter for elements equal to one scalar.

**Why it matters.** `std.mem.countScalar` names the counting operation and keeps its accumulator internal.

**When it matters.** The zero-initialized counter must be immediately followed by a single-capture loop whose only body is the equality test and unit increment.
