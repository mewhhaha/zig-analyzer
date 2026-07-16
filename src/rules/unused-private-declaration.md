# `unused-private-declaration`

[Rule index](RULES.md)

Reports a private declaration that is never referenced in its file.

**Why it matters.** Dead declarations increase search noise and can preserve
obsolete assumptions or dependencies.

**When it matters.** It applies to file-local declarations; public and
externally reachable declarations are outside this proof.
