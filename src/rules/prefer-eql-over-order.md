# prefer-eql-over-order

Reports `std.mem.order(T, a, b) == .eq` or `!= .eq` used to test equality, recommending `std.mem.eql(T, a, b)` or `!std.mem.eql(T, a, b)` instead.

**Why it matters.** `std.mem.order` performs a full lexicographical comparison to determine `<`/`>` ordering, requiring shared-prefix byte-by-byte scanning even if `a.len != b.len`. In contrast, `std.mem.eql` first performs an $O(1)$ length check (`if (a.len != b.len) return false;`), avoiding memory accesses entirely when lengths differ, and uses vector-optimized equality comparisons. Testing for `.eq` order is an unnecessary performance penalty.

**When it matters.** Whenever checking whether two slices are equal or not equal using the `order` comparison function.
