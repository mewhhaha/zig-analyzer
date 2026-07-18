# `combine-identical-switch-prongs`

[Rule index](RULES.md)

Reports adjacent switch prongs with identical bodies and no payload capture.

**Why it matters.** One comma-separated prong makes shared behavior explicit and removes duplicated branch bodies.

**When it matters.** Bodies must be textually identical and comment-free. Captured payloads are excluded because their compatibility requires type information.
