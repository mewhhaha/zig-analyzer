# `non-idiomatic-file-name`

[Rule index](RULES.md)

Reports a Zig source filename whose casing does not match the kind of
declaration it represents.

**Why it matters.** Consistent file and declaration naming makes imports
predictable and navigation faster.

**When it matters.** It applies when the file has a clear primary type or module
role; ambiguous multi-purpose files are not forced into a pattern.
