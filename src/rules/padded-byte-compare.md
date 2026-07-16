# `padded-byte-compare`

[Rule index](RULES.md)

Reports byte-wise comparison of values whose struct layout contains padding.

**Why it matters.** Padding bytes have undefined contents, so logically equal
field values can compare unequal.

**When it matters.** It applies when the compared type and its padding are
proven; compare fields or use `std.meta.eql` instead.
