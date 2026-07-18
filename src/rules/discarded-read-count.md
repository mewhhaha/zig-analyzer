# `discarded-read-count`

[Rule index](RULES.md)

Reports an explicitly discarded byte count returned by a partial-read method.

**Why it matters.** A successful partial read may initialize less than the
entire destination. Using the destination without the returned count can read
stale or undefined bytes.

**When it matters.** Handle the count when partial progress is expected. Use
the corresponding complete-read method when the destination must be filled.
