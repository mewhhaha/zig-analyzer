# identical-conditional-branches

Reports an `if` expression or statement where the `then` and `else` branches have identical bodies.

**Why it matters.** When both branches of a conditional construct execute identical code, the condition check has no effect on the outcome. This almost always indicates a copy-paste mistake where the `else` branch was intended to perform different logic, or dead conditional code that can be removed entirely.

**When it matters.** Always. Branches with intentional duplication should include a distinguishing comment explaining the purpose.
