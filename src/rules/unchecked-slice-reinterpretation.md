# `unchecked-slice-reinterpretation`

[Rule index](RULES.md)

Reports nested `@alignCast` and `@ptrCast` operations applied in either order to
a plain slice without an alignment guarantee in its type.

**Why it matters.** Arbitrary slice storage may be too short or insufficiently
aligned for the destination value. Reinterpreting it as a typed pointer can
panic or read beyond the supplied input.

**When it matters.** Validate the input length and copy bytes into aligned
storage before reading the typed value. Slices carrying an explicit alignment
and value-copying APIs are not reported.
