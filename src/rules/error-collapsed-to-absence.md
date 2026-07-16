# `error-collapsed-to-absence`

[Rule index](RULES.md)

Reports a catch that converts every error to `null` or another empty optional
result.

**Why it matters.** Callers can no longer distinguish a valid absence from an
operation that failed.

**When it matters.** Enable it where failure and not-found are separate domain
outcomes; deliberate lossy probing can be suppressed locally.
