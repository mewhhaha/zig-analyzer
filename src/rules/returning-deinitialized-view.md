# `returning-deinitialized-view`

[Rule index](RULES.md)

Reports a returned view whose backing container is deinitialized by a deferred
cleanup during return.

**Why it matters.** The caller receives a slice or view after its storage has
already been destroyed.

**When it matters.** It applies when the returned binding, backing container,
and deferred `deinit` are all directly connected.
