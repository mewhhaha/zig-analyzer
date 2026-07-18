# `prefer-ends-with`

[Rule index](RULES.md)

Reports a length-guarded `std.mem.eql` comparison against the tail slice of the same sequence.

**Why it matters.** `std.mem.endsWith` states the suffix predicate and owns the short-input boundary.

**When it matters.** The exact `haystack.len >= needle.len and eql(haystack[haystack.len - needle.len..], needle)` shape is required. Unguarded slicing and computed bounds are excluded.
