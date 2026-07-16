# `non-idiomatic-name`

[Rule index](RULES.md)

Reports declarations that do not follow Zig's function, type, or variable naming
conventions.

**Why it matters.** Consistent casing communicates a declaration's role before
its type is inspected and keeps APIs familiar to Zig readers.

**When it matters.** It skips exported, extern, escaped, and uncertain
declarations where renaming could affect an external contract.
