# `discarded-write-count`

[Rule index](RULES.md)

Reports an explicitly discarded return value from a writer's `write` method.

**Why it matters.** `write` may consume only part of its input. Discarding the
count can silently truncate output even when the call itself succeeds.

**When it matters.** Use `writeAll` when all bytes must be written. Keep `write`
when partial progress is intentional and its returned count is handled.
