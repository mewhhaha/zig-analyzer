# `conflicting-build-options`

[Rule index](RULES.md)

Reports one root source configured with different target or optimization options
across compile units.

**Why it matters.** Comptime evaluation and available declarations can differ by
build options, producing inconsistent analysis and behavior from the same root.

**When it matters.** It is a project scan rule that compares explicit build
configurations for the same normalized root path.
