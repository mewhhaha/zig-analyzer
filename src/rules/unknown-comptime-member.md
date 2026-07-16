# `unknown-comptime-member`

[Rule index](RULES.md)

Reports `@hasField` or `@hasDecl` checks that are always false for a resolved
analyzed type shape.

**Why it matters.** Dead comptime branches often indicate a misspelled member or
stale compatibility check.

**When it matters.** It applies only when the container shape is known and no
`usingnamespace` or unresolved declaration can add the member.
