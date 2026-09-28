# prefer-vector-load

Reports `@Vector` literal initializers that manually unpack consecutive elements from an array (`.{ arr[0], arr[1], ... }`), recommending direct vector assignment or coercion.

**Why it matters.** In Zig, fixed-size arrays (`[N]T`) coerce directly to `@Vector(N, T)`. Manually unpacking elements lane-by-lane forces the compiler to emit $N$ scalar memory loads and lane assembly instructions. Direct vector assignment generates a single contiguous SIMD load instruction (`vmovups` on x86, `ldr q0` on ARM).

**When it matters.** Whenever constructing a `@Vector` from consecutive elements of an array.
