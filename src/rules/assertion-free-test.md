# `assertion-free-test`

Reports a test block with no expectation, propagated fallible call, catch, or debug assertion.

**Why it matters.** An accidental assertion-free test passes when behavior is wrong and verifies only that execution did not crash.

**When it matters.** Explicit crash-only tests can suppress the rule, documenting that their absence of an expectation is intentional.
