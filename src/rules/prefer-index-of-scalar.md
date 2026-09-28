# prefer-index-of-scalar

Reports `std.mem.indexOf`, `std.mem.lastIndexOf`, `std.mem.indexOfAny`, `std.mem.lastIndexOfAny`, or `std.mem.count` called with a single-character string literal instead of using `indexOfScalar`, `lastIndexOfScalar`, or `countScalar` with a character literal.

**Why it matters.** Searching for or counting a single byte using slice-search functions (`indexOf`, `lastIndexOf`, `count`) incurs slice overhead and multi-byte comparison logic. In Zig's standard library, `indexOfScalar`, `lastIndexOfScalar`, and `countScalar` are optimized with vector instructions (`@Vector`) to scan for individual scalar elements much faster and express intent directly.

**When it matters.** Whenever searching for or counting a single delimiter, separator, newline, or character within a slice.
