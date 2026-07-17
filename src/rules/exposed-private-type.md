# `exposed-private-type`

Reports a public signature that names a private container type declared in the same file.

**Why it matters.** Callers can receive the value but cannot name its type in their own fields, containers, or signatures.

**When it matters.** The declaration and public signature must both be locally resolvable. Private APIs and externally constrained declarations are ignored.
