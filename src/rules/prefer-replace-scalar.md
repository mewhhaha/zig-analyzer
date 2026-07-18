# `prefer-replace-scalar`

[Rule index](RULES.md)

Reports a pointer-capture loop that replaces every element equal to one scalar.

**Why it matters.** `std.mem.replaceScalar` states the complete in-place replacement operation directly.

**When it matters.** The loop must contain only one equality test and assignment through the captured element pointer, using simple scalar expressions.
