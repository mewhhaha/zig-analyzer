# `prefer-index-of-scalar`

[Rule index](RULES.md)

Reports `std.mem.find`, `findLast`, `findAny`, `findLastAny`, and `count` calls
with a single-byte string literal. It also accepts their legacy `indexOf`
spellings. The fix uses `findScalar`, `findScalarLast`, or `countScalar` with a
character literal.

**Why it matters.** Scalar search states that only one element is needed and
uses the standard library's scalar scanning implementation.

**When it matters.** The needle must decode to one byte. Multi-byte strings and
calls that already use scalar search stay unchanged.
