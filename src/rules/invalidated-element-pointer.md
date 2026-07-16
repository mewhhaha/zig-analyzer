# `invalidated-element-pointer`

[Rule index](RULES.md)

Reports a pointer into a container's elements used after an operation that may
reallocate the backing storage.

**Why it matters.** Container growth can move its allocation and invalidate
element pointers even though the container itself remains valid.

**When it matters.** It applies to pointers derived from recognized `.items`
storage and later invalidating mutations of the same container.
