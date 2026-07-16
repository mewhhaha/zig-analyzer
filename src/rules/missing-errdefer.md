# `missing-errdefer`

[Rule index](RULES.md)

Reports an allocation followed by another fallible operation without an
intervening error-path release.

**Why it matters.** The later failure exits before normal cleanup is installed
and leaks the allocation.

**When it matters.** It applies to recognized allocator bindings and the next
visible fallible operation in the same scope.
