# prefer-empty-slice-len

Reports `std.mem.eql` or `mem.eql` comparisons where one operand is an empty string literal `""` or empty slice `&.{}` instead of checking `.len == 0` or `.len != 0`.

**Why it matters.** Comparing against an empty slice literal via `std.mem.eql` involves a function call, slice length checks, and potential pointer comparisons. In Zig, testing whether a slice is empty is idiomatic, faster, and clearer by checking `slice.len == 0` (or `slice.len != 0`).

**When it matters.** Whenever validating whether a string or slice contains elements.
