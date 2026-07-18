# `prefer-early-return`

[Rule index](RULES.md)

Reports an `if` whose `else` block contains only a return.

**Why it matters.** Inverting the condition into an early-return guard lets the main path continue at the surrounding indentation level.

**When it matters.** The else block must contain exactly one return statement. No edit is offered because removing the main-path block can change declaration scope, defer lifetime, and comment placement.
