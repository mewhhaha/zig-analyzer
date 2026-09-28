# prefer-split-scalar

Reports `std.mem.splitSequence`, `std.mem.splitBackwardsSequence`, `std.mem.tokenizeSequence`, or `std.mem.tokenizeAny` called with a single-character string literal instead of using `splitScalar`, `splitBackwardsScalar`, or `tokenizeScalar` with a character literal.

**Why it matters.** Splitting or tokenizing by a single delimiter using sequence-based iterators incurs the overhead of multi-byte slice matching. Zig's standard library provides specialized scalar iterators (`splitScalar`, `splitBackwardsScalar`, `tokenizeScalar`) that scan for individual characters directly, producing faster code with less register pressure.

**When it matters.** Whenever splitting lines, CSV columns, path components, or words by a single delimiter character.
