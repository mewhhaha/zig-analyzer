# `unused-import`

[Rule index](RULES.md)

Reports a private import alias that is never referenced.

**Why it matters.** Unused imports obscure actual dependencies and keep stale
modules in review and maintenance scope.

**When it matters.** It applies to simple private top-level imports; public
re-exports and uncertain references are retained.
