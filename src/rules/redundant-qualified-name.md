# `redundant-qualified-name`

[Rule index](RULES.md)

Reports a nested type name that repeats its containing namespace.

**Why it matters.** Call sites already qualify the type, so repetition produces
names such as `http.HttpRequest` without adding meaning.

**When it matters.** It applies when the shorter suffix remains clear within the
containing namespace.
