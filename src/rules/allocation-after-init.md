# `allocation-after-init`

Reports direct allocation in a function outside recognized `init*` and `create*` paths.

**Why it matters.** Projects that allocate at startup make out-of-memory a bounded initialization failure instead of an arbitrary runtime failure.

**When it matters.** Enabled by the `disciplined` profile. Only allocator-typed or allocator-named direct receivers are reported; unresolved transitive calls are silent.
