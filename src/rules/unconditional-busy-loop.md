# `unconditional-busy-loop`

[Rule index](RULES.md)

Reports `while (true)` bodies with no visible break, return, or call.

**Why it matters.** Such a loop cannot make externally visible blocking progress
and can consume a CPU indefinitely.

**When it matters.** It targets simple unconditional loop bodies; calls suppress
the warning because they may block, terminate, or alter control flow.
