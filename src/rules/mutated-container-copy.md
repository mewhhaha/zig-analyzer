# `mutated-container-copy`

Reports metadata mutation of an explicitly typed standard-library container copied from a field when neither value is otherwise observed.

**Why it matters.** A reallocating method can move the copy's buffer while the original retains stale length and capacity, losing the mutation or leaking storage.

**When it matters.** The initializer must be exactly `owner.field`, the local type must name a known container through an unshadowed `const std = @import("std")`, and every later use of the local must be a known length- or allocation-changing method. If the field is referenced again, the copy is consumed, the type is inferred, or any expression is ambiguous, the rule stays silent.
