# `modernize-deprecated-builtin`

Reports Zig 0.17's deprecated enum conversion builtins and deprecated target
constants from `@import("builtin")`.

**Why it matters.** `@backingInt` and `@fromBackingInt` replace
`@intFromEnum` and `@enumFromInt`. The new integer-to-enum operation requires
the exact backing integer type. The redundant `cpu`, `os`, `abi`, and
`object_format` constants move under `target` and will be removed in Zig 0.18.

**When it matters.** Enabled by the `modernize` profile. `@intFromEnum` has a
safe name-only fix. Integer-to-enum calls only receive guidance because the
argument may need `@intCast`. Direct builtin imports and aliases whose scoped
declaration is that import receive fixes for `target.cpu`, `target.os`,
`target.abi`, and `target.ofmt`. Custom objects and shadowed aliases are skipped.

See [enum conversion changes](https://ziglang.org/download/0.17.0/release-notes.html#Added-codebackingIntcode-and-codefromBackingIntcode)
and [builtin target deprecations](https://ziglang.org/download/0.17.0/release-notes.html#importbuiltin-Deprecations).
