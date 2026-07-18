# `prefer-multi-sequence-for`

[Rule index](RULES.md)

Reports a zero-based indexed `for` that uses its index only to read a second sequence with an asserted equal length.

**Why it matters.** Iterating both sequences directly removes manual indexing and makes the pairwise traversal explicit.

**When it matters.** An immediately preceding `std.debug.assert` must prove equal lengths, and the index may have no other use. No edit is offered because naming the second capture is local design work.
