# `modernize-global-linkage`

Reports Zig 0.17's removed `GlobalLinkage.internal` and `GlobalLinkage.link_once`
tags in proven standard-library linkage paths or direct linkage options passed
to `@export` and `@extern`.

**Why it matters.** These tags had unclear semantics and incomplete compiler
support. An internal symbol should stay unexported. `weak` may replace
`link_once`, after review of the intended linker behavior.

**When it matters.** Enabled by the `modernize` profile. Standard-library import
and type aliases are resolved within their lexical scopes. Direct anonymous
option initializers and proven `std.lang.ExportOptions` or `ExternOptions`
initializers provide the option context. Unrelated enum tags, nested option
fields, custom receivers, unknown option values, and shadowed imports are
skipped. Neither migration receives an automatic edit.

See [Zig 0.17 global-linkage changes](https://ziglang.org/download/0.17.0/release-notes.html#codeinternalcode-and-codelink_oncecode-Global-Linkage-Removed).
