# `silent-buffer-truncation`

[Rule index](RULES.md)

Reports a void-returning fixed-buffer write that limits its copy with `@min`
without reporting whether all input was written.

**Why it matters.** Callers cannot distinguish a complete write from silently
dropped bytes.

**When it matters.** Return a written byte count, return an error on insufficient
capacity, or document and expose truncation through a more precise contract.
