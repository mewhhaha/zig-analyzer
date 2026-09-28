# prefer-min-max

Reports conditional `if` expressions choosing the lesser or greater of two operands that can be expressed directly with `@min` or `@max`.

**Why it matters.** Zig provides `@min` and `@max` as standard built-in functions. They clearly express bounds, clamping, and extrema directly, work across integer and float types, are vectorized, and avoid repetitive conditional branching.

**When it matters.** Whenever scalar values are compared to select the lesser or greater value.
