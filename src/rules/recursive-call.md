# `recursive-call`

Reports direct recursion and proven two-function mutual recursion in the scanned project.

**Why it matters.** Recursion makes stack consumption depend on input depth; an explicit worklist makes the resource visible and boundable.

**When it matters.** Enabled by the `disciplined` profile. Inline comptime recursion is exempt and reported mutual cycles name both functions.
