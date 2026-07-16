# `redundant-comptime`

[Rule index](RULES.md)

Reports an explicit `comptime` expression already inside a comptime scope.

**Why it matters.** The keyword adds no evaluation guarantee and makes the
actual comptime boundary harder to see.

**When it matters.** It applies to nested expressions where the enclosing block
already requires compile-time evaluation.
