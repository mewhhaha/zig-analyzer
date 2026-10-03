# prefer-math-pow

Reports `std.math.pow` for `f32` or `f64` called with exponents `0.5`, `2`, `1`, or `0` where simpler expressions exist.

**Why it matters.** `std.math.sqrt`, multiplication, and the values `x` or `1` express these constant powers directly. Fixes preserve the requested floating-point type with `@as`, so an integer literal keeps floating-point square-root semantics.

**When it matters.** Computing square roots or small constant powers using `std.math.pow`. Squaring and zero-exponent fixes require a simple operand so the replacement does not duplicate or remove a function call. Integer `pow` and the fallible `std.math.powi` operation are excluded: replacing them with plain arithmetic can change overflow behavior and error handling.

Square-root suggestions need a signed-zero decision: `pow(T, -0.0, 0.5)` returns positive zero, while `sqrt(-0.0)` returns negative zero. Unless the operand is a proven positive numeric literal, the explicit square-root action is excluded from preferred actions and fix-all.
