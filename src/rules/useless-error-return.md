# `useless-error-return`

Reports a fully visible function body that cannot fail although its signature returns an error union.

**Why it matters.** An unearned error union makes every caller handle a failure that cannot occur and misstates the function's contract.

**When it matters.** The rule stays silent for exported functions and any body containing propagation, error construction, calls, catches, or potentially fallible builtins. Removing the error channel is an API decision, so no fix-all edit is offered.
