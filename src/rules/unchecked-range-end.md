# `unchecked-range-end`

[Rule index](RULES.md)

Reports unchecked addition used as a range end in a comparison or slice bound,
such as `offset + bytes.len <= total` or `bytes[offset..offset + length]`, when
the addition itself can overflow before bounds validation runs.

**Why it matters.** A comparison does not protect the arithmetic that produces
its operand. In safety-checked builds the addition can trap; without those
checks it can wrap and make an invalid range appear valid.

**When it matters.** The rule requires unsigned range arithmetic with a
length-like runtime value, or a multi-byte cursor lookahead. It follows simple
range-end temporaries into later comparisons while excluding signed and
floating-point layout arithmetic. Validate `offset <= total` and then compare
the length with `total - offset`, or compute the end with checked arithmetic
such as `std.math.add`.
