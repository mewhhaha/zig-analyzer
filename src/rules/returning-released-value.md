# `returning-released-value`

[Rule index](RULES.md)

Reports a returned owning value that is released by a defer as the function
exits.

**Why it matters.** The caller receives an allocation that has already been
freed or destroyed.

**When it matters.** It applies when the return binding and deferred release
target are the same mechanically identified value.
