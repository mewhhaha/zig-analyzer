# `nullable-pointer-length`

[Rule index](RULES.md)

Reports allocating from a length paired with a nullable C pointer, then
returning the allocation uninitialized when the pointer is null.

**Why it matters.** C APIs commonly require null to imply zero length. Failing
to enforce that contract exposes undefined bytes as initialized output.

**When it matters.** Reject null with a positive length or initialize the output
on every branch before returning it.
