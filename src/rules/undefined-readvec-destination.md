# `undefined-readvec-destination`

[Rule index](RULES.md)

Reports `readVec` calls passed an array of slice descriptors that is still
undefined, including locally declared descriptor structs containing slices.

**Why it matters.** `readVec` reads each destination descriptor before writing
bytes. Undefined slice pointers and lengths can cause invalid memory access.

**When it matters.** Initialize every destination slice before calling
`readVec`. Plain byte arrays and descriptors initialized before the call are
not reported.
