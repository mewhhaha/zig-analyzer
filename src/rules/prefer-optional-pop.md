# `prefer-optional-pop`

[Rule index](RULES.md)

Reports a non-empty check used only to guard a discarded `ArrayList.pop()` result.

**Why it matters.** In current Zig, `pop()` already returns `null` for an empty array list, so the representation-level length check repeats the operation's contract.

**When it matters.** The receiver must resolve to an explicitly typed standard array list, the result must be discarded, and the guard must have no other effect. A surrounding `and` condition is preserved. The rewrite is eligible for fix-all.
