# `discarded-resource`

[Rule index](RULES.md)

Reports explicitly discarded successful results from OS calls and recognized
`std.Io.Dir` or `std.fs.Dir` methods that create files or handles.

**Why it matters.** Discarding the value makes the resource impossible to close
and leaks a finite process-wide handle.

**When it matters.** Bind the returned handle and register its cleanup
immediately, or use an API whose ownership is managed by a containing value.
