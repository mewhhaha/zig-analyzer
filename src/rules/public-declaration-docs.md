# `public-declaration-docs`

[Rule index](RULES.md)

Reports a public declaration without a doc comment.

**Why it matters.** Public APIs need their caller-visible contract, error
behavior, ownership, and constraints documented near the declaration.

**When it matters.** The strict profile is appropriate for libraries that treat
every `pub` declaration as supported API surface.
