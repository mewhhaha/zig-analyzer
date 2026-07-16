# `duplicate-module-import`

[Rule index](RULES.md)

Reports two import spellings in one file that resolve to the same Zig module
path.

**Why it matters.** Multiple identities for one module can duplicate global
state assumptions and make dependency structure misleading.

**When it matters.** It is a project scan rule and requires normalized paths
from the workspace scanner.
