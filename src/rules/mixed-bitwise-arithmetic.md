# `mixed-bitwise-arithmetic`

[Rule index](RULES.md)

Reports bitwise and arithmetic operators mixed without explicit parentheses.

**Why it matters.** Their precedence is easy to misremember, so the written
expression can be read differently from the one Zig evaluates.

**When it matters.** Enable it for low-level arithmetic where the intended
grouping should be explicit to reviewers.
