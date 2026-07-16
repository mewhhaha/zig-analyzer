# `unresolved-call`

[Rule index](RULES.md)

Reports an unqualified call whose function cannot be found in the analyzed
scope.

**Why it matters.** A misspelled or deleted function name otherwise produces
cascading type errors and broken navigation.

**When it matters.** It is useful for ordinary file-local calls; the rule stays
silent when `usingnamespace` makes the visible scope uncertain.
