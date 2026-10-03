# `modernize-deprecated-stdlib`

Reports fully qualified `std` declarations Zig 0.17 deprecates or no longer
ships, naming the current replacement. Also recognizes removed reflection
`fields` access and `dupeZ` on a binding explicitly typed `std.mem.Allocator`.

**Why it matters.** Deprecated aliases disappear in a later release, and
already-removed names fail to compile with no migration advice; naming the
replacement at the use site makes the release migration mechanical.

**When it matters.** Enabled by the `modernize` profile. Only literal
`std.…` paths are matched, not module aliases; declared objects and parameters
that shadow `std` are skipped. Signature-identical renames
carry a fix and participate in fix-all; shape-changing migrations only name
the replacement.

Coverage includes formatting moving to `std.mem` and allocator methods,
bit-set renames, `std.builtin` becoming `std.lang`, optimization-mode names,
removed managed memory pools, and reflection moving to parallel field arrays.
The replacements are checked against the pinned standard library.

See [Zig 0.17 standard-library changes](https://ziglang.org/download/0.17.0/release-notes.html#Standard-Library).
