# `unresolved-call`

[Rule index](RULES.md)

Reports an unqualified call whose function cannot be found in the analyzed
scope.

**Why it matters.** A misspelled or deleted function name otherwise produces
cascading type errors and broken navigation.

**When it matters.** It checks lexical declarations, parameters, and captures,
and also reports bindings proven to hold literal values rather than functions.
Only references inside a scope extended by `usingnamespace` remain silent.
