# `needless-cast`

[Rule index](RULES.md)

Reports nested identical casts or a cast whose operand is proven to already have
the target type.

**Why it matters.** Redundant casts imply a conversion that does not occur and
can conceal the real type flow.

**When it matters.** It applies only with explicit or resolved type equality;
uncertain inferred types are left unchanged.
