# prefer-vector-reduce

Reports serial lane-by-lane arithmetic or bitwise accumulations across vector or array lanes, recommending `@reduce`.

**Why it matters.** Chaining operations such as `v[0] + v[1] + v[2] + v[3]` extracts vector lanes into scalar registers and executes a serial dependency chain with $N \times \text{latency}$. The `@reduce` builtin keeps values within vector registers and executes parallel tree reductions in $O(\log N)$ latency using hardware reduction instructions (e.g. `haddps` or `faddp`).

**When it matters.** Whenever aggregating all lanes of a vector or fixed-size array using addition, multiplication, minimum, maximum, or bitwise operations.
