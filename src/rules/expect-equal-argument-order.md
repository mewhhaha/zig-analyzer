# expect-equal-argument-order

Reports `std.testing.expectEqual` called with `(actual, expected)` where a literal constant is passed as the second argument instead of the first.

**Why it matters.** The signature of `std.testing.expectEqual` is `expectEqual(expected: anytype, actual: anytype) !void`. When test assertions fail, Zig formats error diagnostics as `expected X, found Y`. Passing arguments in reverse order causes test failure output to report the expected constant as the found value and vice versa, creating misleading test reports.

**When it matters.** Whenever writing unit test assertions with `std.testing.expectEqual`.
