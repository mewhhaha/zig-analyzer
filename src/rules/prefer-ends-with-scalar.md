# `prefer-ends-with-scalar`

[Rule index](RULES.md)

Reports calling `std.mem.endsWith` with a 1-character string literal (e.g. `"/"`, `"."`, `"\n"`).

```zig
// Inefficient: constructs slices and calls mem.eql
if (std.mem.endsWith(u8, path, "/")) { ... }

// Fast: single byte load and comparison
if (path.len > 0 and path[path.len - 1] == '/') { ... }
```

**Why it matters.** `std.mem.endsWith` slices the haystack and compares string slices through `std.mem.eql`. Checking the final element directly via `slice.len > 0 and slice[slice.len - 1] == 'c'` compiles to a single memory load and comparison without function call or slice construction overhead.

**When it matters.** The rule reports only when the needle is a 1-character string literal. Multi-character suffixes legitimately require string slice comparisons.
