# `directory-iteration-not-enabled`

[Rule index](RULES.md)

Reports iteration of a standard directory opened with literal options that do
not set `.iterate = true`.

**Why it matters.** Zig requires directory handles to be opened for iteration.
Calling `iterate` on a handle opened without that option is illegal behavior.

**When it matters.** Enable iteration when the opened handle will enumerate
entries. Calls using computed options remain unreported because their value is
not proven locally.
