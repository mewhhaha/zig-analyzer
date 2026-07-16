# `lost-error-context`

[Rule index](RULES.md)

Reports a catch that maps every failure to one replacement error without using
the captured original error.

**Why it matters.** Collapsing distinct failures removes evidence needed for
diagnosis and can make callers handle the wrong abstraction.

**When it matters.** Enable it at error-boundary code where preserving identity,
logging context, or deliberate translation is expected.
