# `configuration-divergent-api`

[Rule index](RULES.md)

Reports a public declaration whose compiler-resolved shape differs between
configured compile units.

**Why it matters.** Callers can observe a different API under another build
configuration even though the source declaration has one name.

**When it matters.** This opt-in project diagnostic requires compiler facts
from at least two successfully analyzed compile units.
