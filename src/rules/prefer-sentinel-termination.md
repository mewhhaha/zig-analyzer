# `prefer-sentinel-termination`

[Rule index](RULES.md)

Reports manual allocation of an extra element followed by writing a zero
terminator.

**Why it matters.** `allocSentinel` and `dupeZ` encode the sentinel in the type
and keep allocation size and termination coupled.

**When it matters.** It applies to recognized simple buffer construction
patterns with an unambiguous zero terminator.
