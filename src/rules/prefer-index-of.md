# `prefer-index-of`

Reports a simple loop whose only purpose is comparing elements and returning a matching index or boolean presence result.

**Why it matters.** `std.mem.findScalar` or `std.mem.find` states search intent and centralizes empty-slice and boundary behavior.

**When it matters.** The loop must have a visible equality test and match exit. A boolean search must be followed immediately by `return false`. Side effects and transformed elements prevent a suggestion.
