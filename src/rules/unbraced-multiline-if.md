# `unbraced-multiline-if`

[Rule index](RULES.md)

Reports an unbraced `if` whose single body statement begins on a later line.

**Why it matters.** Subsequent indented statements can look guarded even though
Zig associates only the first statement with the condition.

**When it matters.** Enable it where multiline control flow should always use
braces to make scope visually unambiguous.
