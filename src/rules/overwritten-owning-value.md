# `overwritten-owning-value`

[Rule index](RULES.md)

Reports assignment over an owning binding before its previous allocation is
released.

**Why it matters.** Replacing the only visible owner loses the address needed to
release the original allocation.

**When it matters.** It applies to simple allocation bindings and optional
owning values in retry loops that are reassigned without an intervening matching
cleanup. It also applies to proven owned fields of stored container elements,
including assignments made through a direct element pointer alias.
