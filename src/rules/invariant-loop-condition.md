# `invariant-loop-condition`

[Rule index](RULES.md)

Reports a `while` condition whose simple numeric comparison is fixed by a
literal `const` binding.

**Why it matters.** Such a condition never controls loop termination. A true
condition exits only through control flow in the body, while a false condition
leaves dead code.

**When it matters.** The rule is an opt-in style check and only evaluates
unambiguous literal constants and simple comparisons.
