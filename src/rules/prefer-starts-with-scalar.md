# `prefer-starts-with-scalar`

[Rule index](RULES.md)

Reports calling `std.mem.startsWith` with a 1-character string literal (e.g. `"-"`, `"/"`, `"."`, `"\n"`).

```zig
// Inefficient: constructs slices and calls mem.eql
if (std.mem.startsWith(u8, arg, "-")) { ... }

// Fast: single byte load and comparison
if (arg.len > 0 and arg[0] == '-') { ... }
```

**Why it matters.** `std.mem.startsWith` takes slice headers, evaluates lengths, performs subslice slicing (`slice[0..1]`), and calls `std.mem.eql`. When testing whether a string begins with a single known character, direct indexing `slice.len > 0 and slice[0] == 'c'` compiles to a single memory load and integer comparison instruction without function call or slice construction overhead.

**When it matters.** The rule reports only when the needle is a 1-character string literal. Multi-character prefixes legitimately require string slice comparisons.
