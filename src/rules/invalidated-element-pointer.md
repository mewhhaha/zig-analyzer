# `invalidated-element-pointer`

[Rule index](RULES.md)

Reports a pointer into a sequence or hash-map entry used after an operation
that may reallocate or rehash the backing storage.

**Why it matters.** Container growth can move its allocation and invalidate
element pointers even though the container itself remains valid.

**When it matters.** It applies to pointers derived from recognized `.items`
storage and entry-returning methods such as `getEntry`, `getPtr`, and
`getOrPut`, followed by an invalidating mutation of the same container. Visible
aliases and summarized helper mutations preserve the container identity. The
container may be a local value, a field, or a function parameter.
