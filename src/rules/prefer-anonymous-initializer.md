# `prefer-anonymous-initializer`

[Rule index](RULES.md)

Reports a named aggregate initializer that repeats a type already established by
the result location.

**Why it matters.** `.{ ... }` avoids duplicating the type and remains correct
when the binding's type spelling changes.

**When it matters.** It applies when the result type is explicit and identical
to the initializer type.
