# identical-bitwise-operands

Reports a bitwise `&`, `|`, or `^` operation whose left-hand and right-hand operands evaluate to the exact same path.

**Why it matters.** Bitwise operations with identical operands are idempotent or self-canceling. In bitwise logic, `x & x` and `x | x` evaluate to `x`, while `x ^ x` always evaluates to `0`. Repeating identical operands in bitwise expressions almost always indicates a copy-paste error or typo where two distinct flags, bitmasks, or variables were intended.

**When it matters.** Always. Redundant bitwise operations indicate either dead code or unintended behavior when testing or combining flags.
