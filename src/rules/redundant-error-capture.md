# `redundant-error-capture`

[Rule index](RULES.md)

Reports a caught error capture that is never referenced.

**Why it matters.** Removing the capture makes it clear that the branch
intentionally handles every error identically.

**When it matters.** It applies when the capture has no use in the catch body,
including indirect textual references checked by the rule.
