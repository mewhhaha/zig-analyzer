# `child-pipe-double-close`

[Rule index](RULES.md)

Reports manually closing a child process pipe before calling the child wait
operation that owns cleanup of that pipe.

**Why it matters.** Waiting may close the same descriptor again, producing
`BADF` or accidentally closing a reused descriptor.

**When it matters.** It applies to locally created standard children and
parameters explicitly typed as `*std.process.Child`. Transfer the pipe state
back to the child API as closed or let `wait` perform its documented cleanup.
