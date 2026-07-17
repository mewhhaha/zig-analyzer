# `modernize-managed-container`

Reports `std.array_list.Managed`, the allocator-storing compatibility container.

**Why it matters.** Current Zig APIs make allocator dependencies explicit at allocating call sites and the managed form is migration-only.

**When it matters.** Enabled by the `modernize` profile. The rule reports without an edit when allocator threading cannot be proven.
