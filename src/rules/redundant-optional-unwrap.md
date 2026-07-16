# `redundant-optional-unwrap`

[Rule index](RULES.md)

Reports force-unwrapping an optional inside a scope where its payload is already
available as a capture.

**Why it matters.** Reusing the capture makes the established non-null invariant
explicit and avoids repeated optional access.

**When it matters.** It applies when the capture corresponds to the same
optional binding.
