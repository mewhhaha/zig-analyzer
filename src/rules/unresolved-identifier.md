# `unresolved-identifier`

[Rule index](RULES.md)

Reports an unqualified non-call identifier whose declaration cannot be found in
the analyzed file.

**Why it matters.** Renaming or deleting a declaration must also update its
uses. Reporting the stale references immediately prevents a misspelled type or
value name from silently degrading navigation and later compiler analysis.

**When it matters.** The rule handles lexical declaration order, parameters,
captures, destructuring, imports, and primitives. Only references inside a
scope extended by `usingnamespace` remain silent, and calls retain the more
specific `unresolved-call` diagnostic.
