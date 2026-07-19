# `local-storage-escape`

[Rule index](RULES.md)

Reports a view or pointer into local storage retained by a returned aggregate,
a callee, a longer-lived container, an output parameter, or direct assignment
to module state.

**Why it matters.** The retained value aliases stack storage that is reused or
expires when the function returns. Later access can observe overwritten bytes
or invalid memory.

**When it matters.** Copy the bytes into storage whose lifetime matches the
retaining aggregate. Calls whose summaries only borrow the argument are not
reported.
