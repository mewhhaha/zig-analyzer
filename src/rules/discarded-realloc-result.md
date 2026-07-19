# `discarded-realloc-result`

[Rule index](RULES.md)

Reports an explicitly discarded slice returned by `realloc` or
`reallocAdvanced`.

**Why it matters.** A successful reallocation may move the allocation and
always returns the authoritative new length. Continuing with the old slice can
use an invalid pointer or stale bounds.

**When it matters.** Store the returned slice and replace the old binding.
Calls whose result is retained are not reported.
