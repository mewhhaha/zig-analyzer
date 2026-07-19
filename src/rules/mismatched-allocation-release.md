# `mismatched-allocation-release`

[Rule index](RULES.md)

Reports an allocation released with the wrong method or through a different
allocator.

**Why it matters.** `alloc`/`free` and `create`/`destroy` are distinct
contracts, and allocator identity must be preserved.

**When it matters.** It applies when both acquisition and release
receiver/method identities are mechanically visible, including allocator
values derived through `.allocator()`.
