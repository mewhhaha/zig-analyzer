# `missing-errdefer`

[Rule index](RULES.md)

Reports a recognized owning acquisition followed by another fallible operation
without an intervening error-path release.

**Why it matters.** The later failure exits before normal cleanup is installed
and leaks the owning value.

**When it matters.** It applies to recognized allocator-owned memory and
standard network streams before the next visible fallible operation in the same
scope.
