# `exposed-private-error-set`

Reports a public function signature that names a private error-set declaration.

**Why it matters.** The published error contract becomes impossible for callers to name or exhaustively switch over.

**When it matters.** Named local error sets are checked; anonymous structural error sets and unresolved inferred sets are left alone.
