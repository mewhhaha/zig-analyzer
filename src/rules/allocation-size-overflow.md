# `allocation-size-overflow`

[Rule index](RULES.md)

Reports unchecked runtime multiplication used as an allocation length.

**Why it matters.** Overflow can allocate less memory than the caller expects,
making subsequent indexed writes unsafe.

**When it matters.** It applies to recognized allocation calls whose size
argument contains runtime multiplication without a visible overflow guard.
