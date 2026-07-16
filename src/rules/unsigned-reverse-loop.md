# `unsigned-reverse-loop`

[Rule index](RULES.md)

Reports a descending unsigned loop whose condition remains true at zero and
whose update then underflows.

**Why it matters.** The loop traps in safe builds or wraps and runs unexpectedly
in modes where overflow is unchecked.

**When it matters.** It applies to the common `index >= 0` reverse-loop shape
with an unsigned index.
