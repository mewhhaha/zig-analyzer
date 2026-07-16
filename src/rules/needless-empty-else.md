# `needless-empty-else`

[Rule index](RULES.md)

Reports an empty else branch.

**Why it matters.** A branch with no effect adds nesting and suggests that an
omitted behavior may exist.

**When it matters.** It applies when removing the branch preserves the
conditional expression's statement context.
