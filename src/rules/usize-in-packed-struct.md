# `usize-in-packed-struct`

[Rule index](RULES.md)

Reports pointer-sized integer fields in packed or extern layouts.

**Why it matters.** `usize` and `isize` change width by target, making
serialized, ABI, or hardware layouts unstable.

**When it matters.** It applies to fields whose containing layout is explicitly
packed or extern.
