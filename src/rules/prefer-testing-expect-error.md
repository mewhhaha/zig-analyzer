# `prefer-testing-expect-error`

[Rule index](RULES.md)

Reports a manual catch-based assertion for one expected error.

**Why it matters.** `expectError` states the test contract directly and reports
unexpected success or a different error clearly.

**When it matters.** It applies to simple catch assertions equivalent to the
standard testing function.
