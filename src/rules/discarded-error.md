# `discarded-error`

[Rule index](RULES.md)

Reports an empty `catch {}` body.

**Why it matters.** Silently converting failure into success hides the original
error and lets execution continue with an unverified result.

**When it matters.** Enable it when errors must be handled, propagated, or
explicitly justified rather than ignored.
