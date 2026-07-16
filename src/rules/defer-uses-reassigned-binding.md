# `defer-uses-reassigned-binding`

[Rule index](RULES.md)

Reports a binding reassigned after deferred cleanup captures it by name.

**Why it matters.** The defer cleans up the replacement value at scope exit and
may leak the original owner.

**When it matters.** It applies when a direct defer target and a later
reassignment refer to the same binding.
