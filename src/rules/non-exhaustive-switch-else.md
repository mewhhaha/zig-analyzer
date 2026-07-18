# `non-exhaustive-switch-else`

[Rule index](RULES.md)

Reports `else` used in a switch over a proven finite enum or tagged union when
at most eight remaining cases can be named.

**Why it matters.** Explicit cases make additions to the type visible at compile
time instead of silently entering a generic fallback.

**When it matters.** It is useful for closed domain types; broad fallbacks over
more than eight cases are treated as intentional grouping. Keep `else` when
forward compatibility is intentional or captures cannot be preserved safely.
