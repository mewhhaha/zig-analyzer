# `unresolved-member`

[Rule index](RULES.md)

Reports a field, declaration, or method access that is absent from a receiver
whose complete local shape is known.

**Why it matters.** Renaming a container member should identify every stale
qualified use immediately instead of waiting for a later compiler pass.

**When it matters.** The rule checks locally declared structs, enums, and
tagged unions, plus simply typed bindings. It stays silent for incomplete
compiler shapes and containers extended with `usingnamespace`.
