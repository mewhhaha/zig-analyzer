# prefer-simd-iota

Reports vector literals initialized with manually written sequential integers (`.{ 0, 1, 2, ... }`) instead of `std.simd.iota`.

**Why it matters.** Initializing vectors with sequential index ranges using manual numeric literals is tedious, error-prone for larger vectors, and obscures the intent of creating an index or ramp vector. Zig's standard library provides `std.simd.iota(T, len)` which generates index vectors cleanly and portably.

**When it matters.** Whenever creating index vectors for SIMD masks, shuffles, table lookups, or coordinate offsets starting from zero.
