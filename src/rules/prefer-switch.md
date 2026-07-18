# `prefer-switch`

[Rule index](RULES.md)

Reports two or more equality-tested branches in one `if`/`else if` chain over a stable integer, enum, or error value.

**Why it matters.** A `switch` states that the branches form one dispatch operation and lets exhaustive cases remain visible to the compiler and reader.

**When it matters.** Each condition must compare the same explicitly typed binding with a distinct integer, character, enum, or error value, and each branch must be braced. Named enum and error-set declarations must be visible in the same file. Inferred and optional types, fields, calls, computed operands, strings, floats, and mixed conditions are left unchanged. This opt-in rule offers no automatic edit because preserving branch comments and choosing exhaustive prongs requires local judgment.
