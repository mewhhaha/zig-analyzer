# `error-value-comparison`

[Rule index](RULES.md)

Reports comparisons between an explicitly typed error set and a concrete error
value that the set cannot contain.

**Why it matters.** The comparison has a constant result and therefore cannot
perform the error discrimination it appears to express.

**When it matters.** The operand must resolve syntactically to an explicit
`error{...}` binding. Comparisons involving inferred or aliased error sets are
left to the compiler rather than guessed.
