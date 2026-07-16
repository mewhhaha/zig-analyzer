# `inclusive-index-bound`

[Rule index](RULES.md)

Reports an inclusive `index <= len`-style assertion used before indexing that
requires `index < len`.

**Why it matters.** Equality still permits an out-of-bounds access, so the
assertion does not establish the safety condition it appears to prove.

**When it matters.** It applies when the asserted index and the following
indexed sequence can be matched directly.
