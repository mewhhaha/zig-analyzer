# `unreleased-allocation`

[Rule index](RULES.md)

Reports a mechanically identified allocation with no visible matching release or
ownership return before scope exit.

**Why it matters.** Repeated execution leaks memory; an `errdefer`-only cleanup
still leaks on successful returns.

The rule also reports a failed `realloc` path that returns a newly allocated
replacement without releasing the still-valid original allocation.

**When it matters.** It targets simple allocator bindings whose allocation and
release methods can be paired without path-sensitive speculation. Direct calls
to same-file helpers are followed when the matching parameter is provably only
borrowed or directly released; indirect and ambiguous calls remain ownership
transfers.
