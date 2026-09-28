# prefer-index-of-scalar

Reports `std.mem.indexOf`, `std.mem.lastIndexOf`, `std.mem.indexOfAny`, or `std.mem.lastIndexOfAny` called with a single-character string literal instead of using `indexOfScalar` or `lastIndexOfScalar` with a character literal.

**Why it matters.** Searching for a single byte using slice-search functions (`indexOf`, `lastIndexOf`) incurs slice overhead and multi-byte comparison logic. In Zig's standard library, `indexOfScalar` and `lastIndexOfScalar` are optimized with vector instructions (`@Vector`) to scan for individual scalar elements much faster and express intent directly.

**When it matters.** Whenever searching for a single delimiter, separator, newline, or character within a slice.
