# `discarded-must-use`

[Rule index](RULES.md)

Reports `_ = call()` when the callable has a declared must-use contract.

**Why it matters.** Some successful return values carry work, ownership, or a
final state that Zig otherwise permits callers to discard.

**When it matters.** Only explicit discard assignments to configured callables
are reported.
