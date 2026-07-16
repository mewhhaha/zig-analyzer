# `constant-comptime-condition`

[Rule index](RULES.md)

Reports an explicitly comptime condition that is the literal `true` or `false`.

**Why it matters.** One branch is permanently inactive in the current source and
can hide obsolete configuration code.

**When it matters.** It is useful after feature or target logic has been
simplified to a constant.
