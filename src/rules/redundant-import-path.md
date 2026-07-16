# `redundant-import-path`

[Rule index](RULES.md)

Reports a relative import path beginning with an unnecessary `./` segment.

**Why it matters.** Canonical spelling makes duplicate paths easier to recognize
and keeps imports consistent.

**When it matters.** It applies to local string-literal imports where removing
`./` preserves resolution.
