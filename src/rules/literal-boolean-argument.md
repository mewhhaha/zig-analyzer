# `literal-boolean-argument`

[Rule index](RULES.md)

Reports literal `true` or `false` arguments passed to boolean parameters in multi-parameter project functions.

**Why it matters.** A literal boolean at a positional call site hides the mode being selected. An enum or options struct carries that meaning into every call.

**When it matters.** The declaration name must be unique in the project and the call must match its exact arity. Single-parameter functions, comptime booleans, and functions whose name already states the boolean parameter are excluded. This strict rule has no automatic fix because choosing the replacement API is a design decision.
