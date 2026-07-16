# `truncating-intcast`

[Rule index](RULES.md)

Reports `@intCast` from a wider integer binding to a narrower target without a
visible range guard.

**Why it matters.** An out-of-range value is safety-checked illegal behavior
rather than an intentional truncation.

**When it matters.** Enable it for input conversion and protocol code where
runtime values must be validated before narrowing.
