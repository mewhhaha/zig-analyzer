# `pointer-only-free`

[Rule index](RULES.md)

Reports reconstructing a fixed-length slice from a many pointer and passing it
to an allocator's `free` without receiving the allocation length.

**Why it matters.** Allocator release contracts require the original allocation
layout; a guessed length can corrupt allocator state or fail safety checks.

**When it matters.** Preserve the original slice or pass the exact allocation
length across the boundary.
