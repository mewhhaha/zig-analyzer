# `copied-io-interface`

[Rule index](RULES.md)

Reports a standard reader or writer interface copied out of its implementation
value.

**Why it matters.** Standard I/O callbacks may recover their implementation
state from the interface's address. A detached copy gives those callbacks the
wrong address and can corrupt memory or crash.

**When it matters.** Keep the concrete reader or writer implementation alive
and pass `&implementation.interface` or `&implementation.writer`. Explicit
state transfers between implementation fields are not reported.
