# `underscore-private-name`

[Rule index](RULES.md)

Reports declarations prefixed with `_` to suggest privacy.

**Why it matters.** Zig privacy is structural rather than name-based, so the
prefix communicates a contract the language does not enforce.

**When it matters.** It is useful when migrating conventions from languages
where underscore prefixes control or conventionally mark visibility.
