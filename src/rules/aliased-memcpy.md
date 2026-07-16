# `aliased-memcpy`

[Rule index](RULES.md)

Reports `@memcpy` source and destination slices derived from the same base
value.

**Why it matters.** Overlap is undefined for `@memcpy`; directional copy
routines are required when ranges may alias.

**When it matters.** It applies when both slice expressions have a common
mechanically proven base, even if exact overlap is not calculated.
