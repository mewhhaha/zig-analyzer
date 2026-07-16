# `missing-switch-prong`

[Rule index](RULES.md)

Reports a switch over a proven finite enum or tagged union that omits cases and
has no `else` prong.

**Why it matters.** Naming every case keeps behavior synchronized when a type
gains a new tag and avoids a compiler failure at a less useful location.

**When it matters.** It applies when the operand type and its cases are known,
including compiler-resolved comptime-generated named types.
