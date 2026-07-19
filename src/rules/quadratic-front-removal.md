# `quadratic-front-removal`

[Rule index](RULES.md)

Reports `orderedRemove(0)` while a loop drains the same `ArrayList` according to
its remaining length.

**Why it matters.** Every ordered front removal shifts all remaining elements.
Draining the complete list this way performs quadratic work.

**When it matters.** This disciplined-profile rule requires a visible
`ArrayList`, a loop condition over that list's `items.len`, and a literal zero
removal index. One-off front removal and non-front removal remain unreported.
