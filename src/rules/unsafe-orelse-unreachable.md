# `unsafe-orelse-unreachable`

[Rule index](RULES.md)

Reports `orelse unreachable` used to unwrap an optional.

**Why it matters.** An absent value becomes a low-context panic rather than an
handled case or a clearly documented invariant.

**When it matters.** The strict profile is useful at trust boundaries; proven
internal invariants may instead use an assertion with an explanation.
