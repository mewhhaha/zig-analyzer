# `double-release`

[Rule index](RULES.md)

Reports more than one visible release of the same allocation in one control-flow
scope.

**Why it matters.** Releasing storage twice can corrupt allocator state or
trigger safety checks.

**When it matters.** It targets duplicate `free` or `destroy` operations whose
binding identity is unambiguous.
