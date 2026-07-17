# `unbounded-loop`

Reports a `while` loop with no visible comparison bound, iterator exhaustion, or counter guard.

**Why it matters.** An unstated bound turns corrupted input or a missing event into a hang with no declared worst case.

**When it matters.** Enabled by the `disciplined` profile. Recognized blocking event-loop dispatch and iterator loops are exempt.
