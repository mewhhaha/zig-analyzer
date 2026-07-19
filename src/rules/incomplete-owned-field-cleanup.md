# `incomplete-owned-field-cleanup`

[Rule index](RULES.md)

Reports an aggregate or container whose cleanup drops proven owned fields.

**Why it matters.** Every owned field must be released on normal cleanup.
Omitting one leaks that allocation whenever the aggregate is destroyed.

**When it matters.** Ownership evidence comes from recognized owned returns
stored in aggregate fields or container elements. Cleanup that is delegated or
passes an element to an opaque cleanup function remains opaque. Destructive
container operations are checked in any method, not only methods named
`deinit` or `clear`.
