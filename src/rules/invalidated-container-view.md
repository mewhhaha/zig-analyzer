# `invalidated-container-view`

[Rule index](RULES.md)

Reports a slice or iterator used after an operation that may move or invalidate
its container's backing storage.

**Why it matters.** Growth and structural mutation can leave previously obtained
views pointing at stale memory or state.

**When it matters.** It applies to recognized container view methods followed by
known invalidating operations on the same container.
