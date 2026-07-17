# `allocator-first-parameter`

Reports a `std.mem.Allocator` parameter that is not first after an optional `self` parameter.

**Why it matters.** Matching the standard library's parameter grammar makes allocating APIs predictable at every call site.

**When it matters.** External signatures are exempt. The allocator type must be spelled explicitly and resolved syntactically.
