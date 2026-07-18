# `unbounded-loop`

Reports a `while` loop with no visible comparison bound, exhaustion condition, or counter guard.

**Why it matters.** An unstated bound turns corrupted input or a missing event into a hang with no declared worst case.

**When it matters.** Enabled by the `disciplined` profile. Iterator and reader exhaustion, sentinel traversal, queue drains, blocking waits, event-loop dispatch, and retry-on-interruption loops are exempt.
