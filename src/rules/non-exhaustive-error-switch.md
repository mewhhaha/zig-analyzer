# `non-exhaustive-error-switch`

[Rule index](RULES.md)

Reports a switch over a known finite error set that does not name every error.

**Why it matters.** Exhaustive error handling makes newly introduced failures
visible instead of routing them through an accidental fallback.

**When it matters.** It applies when the operand's error set is explicitly
known; inferred or global error sets are not expanded speculatively.
