# `prefer-expression-initializer`

[Rule index](RULES.md)

Reports a local initialized with `undefined` and then assigned exactly once by every branch of an adjacent `if` or `switch`.

**Why it matters.** Initializing a `const` from the control-flow expression makes assignment complete by construction and removes an avoidable undefined state.

**When it matters.** Every direct branch must contain only one assignment to the local. Else-if chains, partial branches, self-references, and branches with setup work are excluded. No edit is offered because flattening branch blocks can change scopes and comments.
