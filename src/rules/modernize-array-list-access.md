# `modernize-array-list-access`

Reports deprecated `getLastOrNull()` and `getLast()` calls on proven standard
`ArrayList` / `array_list.Aligned` values. Fixes use `last()` and `last().?`,
respectively, preserving the optional result or nonempty requirement.

**Why it matters.** Zig 0.17 consolidates the last-element API around the
optional `last()` method. `getLast` remains as a deprecated compatibility method.

**When it matters.** Enabled by the `modernize` profile. Receiver proof follows
explicit types, known list initializers, namespace aliases and scoped type/value
aliases rooted in `@import("std")`. Legacy unmanaged and aligned type aliases
are recognized. Custom methods, unknown receivers, mutable namespace/type aliases
and shadowed aliases are skipped. Mutable list values retain their known type.
Zero-argument calls receive safe quick fixes; other call shapes receive
advice only. Comments inside zero-argument calls are preserved.

```zig
// Before
const optional = list.getLastOrNull();
const required = list.getLast();

// After
const optional = list.last();
const required = list.last().?;
```

See the [Zig 0.17 ArrayList changes](https://ziglang.org/download/0.17.0/release-notes.html#ArrayList).
