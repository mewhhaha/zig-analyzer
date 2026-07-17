# `unreachable-public-declaration`

[Rule index](RULES.md)

Reports a public declaration outside every successfully compiler-analyzed
compile unit's import graph.

**Why it matters.** Public-looking code outside every build root is neither
compiled nor available to consumers.

**When it matters.** This opt-in project diagnostic stays silent unless every
discovered build root was analyzed successfully and the source import graph has
no unresolved build-named module edge.
