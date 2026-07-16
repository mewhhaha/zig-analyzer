# `prefer-testing-expect-equal`

[Rule index](RULES.md)

Reports `std.testing.expect(actual == literal)`-style assertions.

**Why it matters.** `expectEqual` reports expected and actual values, producing
a substantially more useful test failure.

**When it matters.** It applies when one side is a simple literal and argument
order can be established safely.
