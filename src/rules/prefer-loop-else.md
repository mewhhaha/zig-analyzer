# `prefer-loop-else`

[Rule index](RULES.md)

Reports a boolean flag whose only purpose is to remember that a loop broke before fallback work.

**Why it matters.** A loop `else` branch directly expresses work that runs only when iteration completes without `break`.

**When it matters.** The loop body must consist only of a matching `if` that sets the flag and breaks, followed immediately by an `if (!flag)` fallback. Flags read afterward are excluded.
