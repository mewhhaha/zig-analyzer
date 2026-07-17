# `mutated-container-copy`

Reports mutation of a local `var` copied from a container field when the copy is neither returned nor written back.

**Why it matters.** A reallocating method can move the copy's buffer while the original retains stale length and capacity, losing the mutation or leaking storage.

**When it matters.** Only known length- or allocation-changing methods on a direct field copy are recognized. Copies returned or assigned back are silent.
