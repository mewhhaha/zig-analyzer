# `modernize-managed-container`

Reports `std.array_list.Managed`, `std.array_list.AlignedManaged`, and
`std.bit_set.DynamicManaged`, the allocator-storing compatibility containers.

**Why it matters.** Current Zig APIs make allocator dependencies explicit at allocating call sites and the managed form is migration-only.

**When it matters.** Enabled by the `modernize` profile. The rule reports without an edit when allocator threading cannot be proven.

Nested members such as `wrapper.std.array_list.Managed` and local bindings
that shadow `std` are skipped.
