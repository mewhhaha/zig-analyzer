# `prefer-range-for`

Reports an exact zero-based, unit-step counter `while` loop that a range `for` expresses directly.

**Why it matters.** A range keeps the iteration space in one place and makes the index immutable.

**When it matters.** The counter must be a `usize`, must not be changed in the
body, and must not be read after the loop. The proven rewrite is eligible for
fix-all.
