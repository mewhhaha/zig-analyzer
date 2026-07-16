# `undefined-value-escape`

[Rule index](RULES.md)

Reports a value initialized with `undefined` that is read or escapes before
whole-value initialization.

**Why it matters.** Reading undefined bytes is illegal behavior and partial
initialization can expose invalid fields.

**When it matters.** It applies when the analyzer sees the binding escape or be
consumed before a proven whole-value write.
