# `prefer-memset`

Reports a full-slice pointer-capture loop that only assigns one invariant value to each element.

**Why it matters.** `@memset` names the fill operation and gives the compiler its strongest optimization shape.

**When it matters.** The body must be a single `element.* = value` statement and the value must not refer to the capture. Exact matches receive a fix-all rewrite.
