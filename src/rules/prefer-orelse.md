# `prefer-orelse`

[Rule index](RULES.md)

Reports an optional `if` expression whose present branch returns the captured payload unchanged.

**Why it matters.** `orelse` names the fallback operation directly without introducing a capture that adds no behavior.

**When it matters.** The condition and capture must be simple identifiers, and the error-union form with an error capture is excluded. No edit is offered because the fallback expression boundary may depend on its surrounding expression.
