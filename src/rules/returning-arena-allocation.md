# `returning-arena-allocation`

[Rule index](RULES.md)

Reports a returned value allocated from a local arena that is deinitialized
before the function finishes returning.

**Why it matters.** Arena deinitialization invalidates every allocation made
from it, so the returned value immediately dangles.

**When it matters.** It applies to locally created arenas with visible deferred
deinitialization and recognizable allocation provenance.
