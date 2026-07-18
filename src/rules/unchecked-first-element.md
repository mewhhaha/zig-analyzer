# `unchecked-first-element`

[Rule index](RULES.md)

Reports a public function indexing a plain-slice parameter at zero without a
visible proof that the slice is non-empty.

**Why it matters.** An empty plain slice has no first element, so indexing it
traps in safe builds and is undefined behavior when safety checks are disabled.

**When it matters.** The rule checks externally callable boundaries with known
plain slice types and stays quiet for private invariants, fixed arrays,
sentinel-terminated slices, and visibly guarded accesses.
