# `cleanup-after-fallible-operation`

[Rule index](RULES.md)

Reports cleanup registered only after another fallible operation can exit the
scope.

**Why it matters.** An error between acquisition and cleanup registration leaks
the newly acquired resource.

**When it matters.** It applies to recognized resource bindings followed by
`try` or another proven early-error point before `defer` or `errdefer`.
