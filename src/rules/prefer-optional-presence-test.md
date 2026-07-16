# `prefer-optional-presence-test`

[Rule index](RULES.md)

Reports an optional capture used only to test whether the optional is present.

**Why it matters.** Comparing with `null` expresses a presence test without
introducing an unused payload binding.

**When it matters.** It applies when the capture has no semantic use in the
branch.
