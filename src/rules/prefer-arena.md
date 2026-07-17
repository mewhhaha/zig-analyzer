# `prefer-arena`

Reports a scope with at least three allocations from one allocator and a matching release for each.

**Why it matters.** That lifetime already behaves like an arena; making it structural removes repetitive cleanup and leak opportunities.

**When it matters.** Only same-scope allocation and release shapes are counted. No rewrite is offered because changing ownership strategy is a design decision.
