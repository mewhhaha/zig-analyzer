# `modernize-deprecated-io`

Reports known pre-`std.Io` reader, writer, and buffering adapters reached through `std.io` or `std.Io`.

Also reports `std.Io.Reader.readAlloc`, deprecated in Zig 0.17 in favor of `readAllocAll` and scheduled for removal after 0.17. This exact alias receives a safe member-name fix when its reader type or value is proven, including immutable import and type aliases, typed parameters, and `Reader.fixed` results.

**Why it matters.** The I/O redesign moves interface and buffer ownership into explicit current types; old adapters delay an otherwise mechanical release migration.

**When it matters.** Enabled by the `modernize` profile. Shape-changing migrations name the replacement but do not edit code automatically.

Other standard-library namespaces, nested `std` members, and declared local
bindings that shadow `std` are skipped.

Reader migration checks also skip custom readers, unknown factories, member projections, and mutable namespace or type aliases. The replacement is documented in [Zig 0.17's reader implementation](https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/std/Io/Reader.zig).
