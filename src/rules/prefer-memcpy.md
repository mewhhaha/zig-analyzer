# `prefer-memcpy`

Reports a full-range element loop that copies `source[index]` to a distinct `destination[index]`.

**Why it matters.** `@memcpy` names the operation and asserts the equal-length contract.

**When it matters.** Source and destination must be distinct direct bindings and the body must contain only the corresponding store. Exact matches receive a fix-all rewrite.
