# prefer-vector-splat

Reports `@Vector` literal initializers that repeat the same scalar value across all lanes, recommending `@splat` instead.

**Why it matters.** In unoptimized or debug builds, constructing a vector with repeated lane literals (`.{ val, val, val, val }`) generates individual stack allocations or serial lane insert instructions. The `@splat` builtin compiles to a single hardware SIMD broadcast instruction (such as `vbroadcastss`/`vbroadcastsd` on x86 or `dup` on ARM NEON), or a zero-latency register clear for `@splat(0)`.

**When it matters.** Whenever a `@Vector` literal is initialized with identical scalar expressions across all lanes.
