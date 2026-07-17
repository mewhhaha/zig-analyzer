# `assertion-free-branching`

Reports a nontrivial function with computed indexing but no visible assertion, unreachable arm, or early-return bounds validation.

**Why it matters.** Assertions state the invariant behind pointer and range computation where Debug builds can check it.

**When it matters.** Enabled by the `disciplined` profile. This conservative heuristic requires both a minimum function size and a direct computed index.
