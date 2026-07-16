# `prefer-testing-expect-approx`

[Rule index](RULES.md)

Reports a manual absolute-difference floating-point assertion.

**Why it matters.** `expectApproxEqAbs` communicates tolerance semantics and
provides a more useful failure message.

**When it matters.** It applies when the analyzer recognizes the standard
absolute-difference comparison shape.
