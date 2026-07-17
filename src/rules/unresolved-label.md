# `unresolved-label`

[Rule index](RULES.md)

Reports a `break` or `continue` whose named target is not an enclosing labeled
block or loop.

**Why it matters.** A misspelled label changes valid control flow into a hard
compile error, often far from the declaration being renamed.

**When it matters.** The rule applies to explicit named branch targets. It
does not infer targets for unlabeled branches.
