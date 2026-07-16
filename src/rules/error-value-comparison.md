# `error-value-comparison`

[Rule index](RULES.md)

Reports equality comparisons against a concrete error value.

**Why it matters.** Direct comparison can widen the inferred error set, while a
switch preserves exhaustive checking as errors evolve.

**When it matters.** It is useful when branching on error identity and the set
of possible failures should remain explicit.
