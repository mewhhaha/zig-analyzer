# `missing-resource-cleanup`

[Rule index](RULES.md)

Reports a recognized resource or mutex with no visible cleanup, unlock, or
ownership transfer.

**Why it matters.** File handles, clients, containers, and locks often retain
memory or system state even when no raw allocation is visible.

**When it matters.** It applies to known constructor/cleanup pairs and lock
scopes, including error paths that leave a mutex locked. Cleanup of every
resource-owning aggregate field satisfies the contract; custom ownership
conventions require explicit project policy or code.
