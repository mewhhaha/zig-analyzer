# `modernize-deprecated-stdlib`

Reports fully qualified `std` declarations the pinned Zig release deprecates or
no longer ships, naming the current replacement.

**Why it matters.** Deprecated aliases disappear in a later release, and
already-removed names fail to compile with no migration advice; naming the
replacement at the use site makes the release migration mechanical.

**When it matters.** Enabled by the `modernize` profile. Only literal
`std.…` paths are matched, not module aliases. Signature-identical renames
carry a fix and participate in fix-all; shape-changing migrations only name
the replacement.
