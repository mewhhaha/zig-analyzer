# `unknown-comptime-member`

[Rule index](RULES.md)

Reports `@hasField` or `@hasDecl` checks that are always false, and `@field`
lookups that cannot succeed, for a resolved analyzed type shape.

**Why it matters.** Dead comptime branches often indicate a misspelled member or
stale compatibility check.

In Zig 0.17, `@hasDecl` sees public declarations only, including when the check
is in the declaration's own file. `@hasField` checks fields; local `@field`
lookups may still access private declarations.

**When it matters.** It applies only when the container shape is known and no
`usingnamespace` or unresolved declaration can add the member.
