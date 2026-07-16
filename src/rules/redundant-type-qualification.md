# `redundant-type-qualification`

[Rule index](RULES.md)

Reports a fully qualified enum value when the result location already
establishes its type.

**Why it matters.** An inferred `.case` literal keeps the value focused on the
selected case and avoids repeating the surrounding type annotation.

**When it matters.** It applies when the declaration has an explicit result type
matching the qualification exactly.
