# `mutable-pointer-parameter`

[Rule index](RULES.md)

Reports a `*T` parameter whose pointee is only read.

**Why it matters.** `*const T` documents the callee's contract and allows
callers to pass immutable values.

**When it matters.** It skips callbacks, `deinit` conventions, escaping
addresses, mutable captures, loops, and other cases where indirect mutation is
uncertain.
