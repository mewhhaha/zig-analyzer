# `use-after-release`

[Rule index](RULES.md)

Reports a visible use of an allocation after its matching release.

**Why it matters.** The value no longer refers to live storage, so reads and
writes are invalid.

**When it matters.** It applies to ordered uses and releases in the same
conservatively analyzed scope.
