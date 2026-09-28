# `nan-comparison`

[Rule index](RULES.md)

Reports comparison with a NaN value (`std.math.nan`, `std.math.snan`, `math.nan`, or `math.snan`).

**Why it matters.** In IEEE 754 floating-point arithmetic, NaN (Not-a-Number) values never compare equal to any value, including themselves. Equality comparisons (`==`) always evaluate to `false`, and inequality comparisons (`!=`) always evaluate to `true`. Similarly, ordered comparisons (`<`, `<=`, `>`, `>=`) always evaluate to `false`. To test whether a floating-point value is NaN, use `std.math.isNan(x)`.

**When it matters.** Whenever comparing a value against a NaN constructor function. For equality and inequality comparisons, an automatic quickfix rewrites the expression to `std.math.isNan(x)` or `!std.math.isNan(x)`.
