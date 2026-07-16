# `never-mutated-var`

[Rule index](RULES.md)

Reports a local `var` whose binding and reachable mutable aliases are never
mutated.

**Why it matters.** `const` communicates the actual invariant, prevents
accidental later mutation, and gives readers a smaller state space to reason
about.

**When it matters.** It applies to function and test locals after conservative
alias, pointer, cleanup, capture, and mutation checks.
