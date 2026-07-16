# `unsorted-imports`

[Rule index](RULES.md)

Reports a safely reorderable top-level import block that is not grouped and
sorted by path.

**Why it matters.** Stable import order reduces merge conflicts and makes
dependencies easier to audit.

**When it matters.** It applies only to contiguous, simple imports whose
directly attached comments can move with them unambiguously.
