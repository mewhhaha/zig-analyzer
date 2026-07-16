# `unreleased-allocation`

[Rule index](RULES.md)

Reports a mechanically identified allocation with no visible matching release or
ownership return before scope exit.

**Why it matters.** Repeated execution leaks memory; an `errdefer`-only cleanup
still leaks on successful returns.

**When it matters.** It targets simple allocator bindings whose allocation and
release methods can be paired without path-sensitive speculation.
