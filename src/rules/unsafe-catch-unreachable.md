# `unsafe-catch-unreachable`

[Rule index](RULES.md)

Reports `catch unreachable` on an operation known to be fallible.

**Why it matters.** A recoverable or propagatable failure becomes a runtime
assertion with little error context.

**When it matters.** It is useful where failures should be handled or returned;
intentional impossible-error invariants may warrant an explicit assertion and
explanation.
