# prefer-vector-op

Reports `@Vector` literal initializers that perform element-wise arithmetic on two vectors or arrays, recommending direct vector operators instead.

**Why it matters.** Zig natively supports arithmetic (`+`, `-`, `*`, `/`) and bitwise operators directly on `@Vector` types. Constructing a vector by performing scalar arithmetic lane-by-lane emits $N$ scalar operations and packing instructions. Operating directly on vectors compiles to single SIMD vector instructions (`vaddps`, `vmulps`, etc.).

**When it matters.** Whenever computing element-wise operations between vectors or arrays to initialize a `@Vector`.
