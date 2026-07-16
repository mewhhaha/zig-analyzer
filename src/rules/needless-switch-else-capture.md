# `needless-switch-else-capture`

[Rule index](RULES.md)

Reports an unused capture on a switch `else` prong.

**Why it matters.** An unused name suggests that the fallback value influences
behavior when it does not.

**When it matters.** It applies when the capture can be removed without
affecting the prong body.
