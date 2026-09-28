# `redundant-slice-end`

[Rule index](RULES.md)

Reports a slice operation where the upper bound explicitly specifies `<slice>.len`.

**Why it matters.** In Zig, open-ended slicing syntax `s[start..]` implicitly slices to the end of the sequence (`s.len`). Explicitly repeating `s[start..s.len]` is redundant and less idiomatic.

**When it matters.** It applies when the upper slice bound is an exact match for the sliced base expression followed by `.len`.
