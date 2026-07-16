# `iterator-invalidated-during-loop`

[Rule index](RULES.md)

Reports mutation of a map while an iterator over that map is active.

**Why it matters.** Structural mutation can invalidate the iterator and make the
next iteration observe stale internal state.

**When it matters.** It applies to recognized iterator bindings and invalidating
methods on the same map inside the loop.
