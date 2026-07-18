# `prefer-starts-with`

[Rule index](RULES.md)

Reports `std.mem.indexOf(..., haystack, needle) == 0` prefix tests.

**Why it matters.** `std.mem.startsWith` states the prefix predicate without exposing a search position.

**When it matters.** The comparison must use exactly zero and a three-argument `std.mem.indexOf` call. Other position checks remain searches.
