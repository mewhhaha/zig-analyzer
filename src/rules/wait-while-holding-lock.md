# `wait-while-holding-lock`

[Rule index](RULES.md)

Reports a loop that waits for shared state while retaining the lock another
visible function needs to update that state.

**Why it matters.** The signaling operation cannot acquire the lock, so the
wait condition can never become true.

**When it matters.** The rule requires a visible matching lock and atomic state
update in another function of the same source file.
