# `duplicate-import`

[Rule index](RULES.md)

Reports the same module path imported more than once in one file.

**Why it matters.** Duplicate aliases add dependency noise and can make readers
wonder whether two module instances differ.

**When it matters.** It applies to simple private top-level imports where path
equality and comment-safe removal are clear.
