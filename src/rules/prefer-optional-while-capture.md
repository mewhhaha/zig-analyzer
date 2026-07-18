# `prefer-optional-while-capture`

[Rule index](RULES.md)

Reports `while (true)` loops whose first statement unwraps an optional with `orelse break`.

**Why it matters.** Capturing the optional in the `while` condition states both iteration and exhaustion in one place.

**When it matters.** The declaration must be the first loop statement and use an unlabeled, valueless break. Labeled exits and setup before iteration are excluded.
