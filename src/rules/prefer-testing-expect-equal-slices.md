# `prefer-testing-expect-equal-slices`

[Rule index](RULES.md)

Reports manual slice comparison in a test assertion.

**Why it matters.** `expectEqualSlices` identifies the mismatching element and
preserves expected/actual context.

**When it matters.** It applies when the element type and both slice operands
are recognizable.
