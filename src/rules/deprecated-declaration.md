# `deprecated-declaration`

Reports references to declarations whose first doc line starts with `Deprecated:`.

**Why it matters.** Zig deprecations otherwise remain prose until a later release removes the declaration and breaks the build.

**When it matters.** The local target must be unambiguous. The diagnostic carries the declaration author's first-line migration advice.
