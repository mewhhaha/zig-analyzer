# `prefer-testing-expect-equal-strings`

[Rule index](RULES.md)

Reports byte-string equality assertions that use a generic boolean or equality
check.

**Why it matters.** `expectEqualStrings` presents readable string differences
instead of only reporting a failed boolean condition.

**When it matters.** It applies when both operands are proven string or
byte-slice values in a supported test assertion shape.
