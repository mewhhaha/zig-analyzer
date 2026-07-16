# `prefer-optional-capture`

[Rule index](RULES.md)

Reports an optional checked for non-null and then force-unwrapped in the guarded
branch.

**Why it matters.** An optional capture expresses and names the proven payload
without repeating `.?` operations.

**When it matters.** It applies when all relevant unwraps can be replaced with a
collision-free capture without changing mutation semantics.
