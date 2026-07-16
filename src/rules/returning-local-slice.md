# `returning-local-slice`

[Rule index](RULES.md)

Reports a returned slice that points into a local array.

**Why it matters.** The array's storage expires at function return, leaving the
caller with a dangling slice.

**When it matters.** It applies when the returned slice and local backing array
can be connected by binding identity.
