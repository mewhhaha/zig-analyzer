# `duplicate-c-import`

[Rule index](RULES.md)

Reports identical `@cImport` translation blocks in different project files.

**Why it matters.** Centralizing translated declarations avoids repeated
compiler work and prevents separate C namespaces from drifting.

**When it matters.** It is a project scan rule and compares normalized
translation contents across source files.
