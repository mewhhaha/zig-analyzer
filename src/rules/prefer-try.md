# `prefer-try`

[Rule index](RULES.md)

Reports a caught error that is immediately returned unchanged.

**Why it matters.** `try` states direct propagation concisely and avoids an
unnecessary capture and catch expression.

**When it matters.** It applies when the enclosing function can return the error
and the catch performs no additional work.
