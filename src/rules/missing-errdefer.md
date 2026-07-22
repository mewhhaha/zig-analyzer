# `missing-errdefer`

[Rule index](RULES.md)

Reports a recognized owning acquisition followed by another fallible operation
or explicit error return without an intervening error-path release.

**Why it matters.** The later failure exits before normal cleanup is installed
and leaks the owning value.

**When it matters.** It applies to recognized allocator-owned memory and
standard network streams before the next visible fallible operation in the same
scope. Arena provenance is scoped to the function that establishes it; an
explicit function contract stating that its allocator should be an arena also
satisfies the lifetime proof, as does the `contracts.arena-allocators` project
setting. The rule also follows ownership assigned into a
partially initialized local aggregate or heap object, and cleanup-capable values
awaiting a fallible container insertion. Known borrowing I/O and filesystem
operations do not erase the acquisition's ownership provenance.
