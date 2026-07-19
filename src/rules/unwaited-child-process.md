# `unwaited-child-process`

[Rule index](RULES.md)

Reports a child returned by `std.process.spawn` that reaches the end of its
scope without `wait`, `kill`, or ownership transfer.

**Why it matters.** An unwaited child retains process status and associated OS
resources after it exits.

**When it matters.** Wait for or kill the child in the same scope, or transfer
the child value to an owner whose lifetime contract includes that operation.
