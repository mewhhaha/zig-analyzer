# prefer-math-pow

Reports `std.math.pow` called with exponents `0.5`, `2`, `1`, or `0` where dedicated hardware operations or simpler algebraic expressions exist.

**Why it matters.** The general `std.math.pow` function computes transcendentals using logarithms and exponentials ($e^{y \ln x}$), taking dozens to hundreds of clock cycles and potentially drifting in floating-point precision. For square roots (`pow(T, x, 0.5)`), modern CPUs provide single-instruction hardware square roots via `std.math.sqrt`. For squares (`pow(T, x, 2)`), simple multiplication executes in a single clock cycle. For `pow(T, x, 1)` and `pow(T, x, 0)`, the results are algebraically identical to `x` and `1`.

**When it matters.** Whenever computing square roots or small constant powers using `std.math.pow` or `std.math.powi`.
