# `allocation-size-overflow`

[Rule index](RULES.md)

Reports unchecked runtime multiplication used as an allocation length.

**Why it matters.** Overflow can allocate less memory than the caller expects,
making subsequent indexed writes unsafe.

**When it matters.** It applies to recognized allocation calls whose size
argument directly contains runtime multiplication. The risk is target- and
range-dependent: a product that fits `usize` on a 64-bit target may overflow
on a narrower supported target. When project invariants establish tighter
bounds than the types express, use a focused suppression rather than changing
the portable arithmetic check.
