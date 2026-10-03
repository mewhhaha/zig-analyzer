# `modernize-container-init`

Reports removed `initEmpty()` and `initFull()` calls on proven fixed-size
`std.bit_set.Integer`, `Array`, `Static` and `std.enums.EnumSet` types, including
their legacy aliases. Fixes use the type's `empty` and `full` values.

**Why it matters.** Zig 0.17 replaces these zero-argument constructors with
constants. Dynamic bitsets still require allocator and length arguments;
`EnumMap.initFull(value)` also remains supported.

**When it matters.** Enabled by the `modernize` profile. Proof follows scoped
constant type/namespace aliases rooted in `@import("std")`; custom, mutable and
shadowed aliases are skipped. Zero-argument calls receive safe quick fixes. Calls with arguments
or comments inside their parentheses receive advice without an edit.

```zig
const Bits = std.bit_set.Integer(8);

// Before
const cleared = Bits.initEmpty();
const filled = Bits.initFull();

// After
const cleared = Bits.empty;
const filled = Bits.full;
```

See the [Zig 0.17 standard-library changes](https://ziglang.org/download/0.17.0/release-notes.html#Standard-Library).
