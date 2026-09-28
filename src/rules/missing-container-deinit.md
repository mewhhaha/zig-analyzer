# `missing-container-deinit`

[Rule index](RULES.md)

Reports local unmanaged containers that are mutated with allocating methods but have no visible `deinit`, slice conversion, or ownership transfer.

**Why it matters.** In modern Zig, unmanaged containers such as `std.ArrayList`, `std.ArrayListUnmanaged`, and `std.StringHashMapUnmanaged` are initialized with `.empty` without passing an allocator upfront. Because memory is only allocated on later mutating operations (e.g. `append`, `put`, `getOrPut`), developers frequently omit `defer container.deinit(allocator);`, leading to silent heap leaks on all exit paths.

**When it matters.** The rule inspects local `var` containers within functions and tests that call allocating methods (`append`, `appendSlice`, `put`, `getOrPut`, `ensureTotalCapacity`, etc.). A `defer container.deinit(allocator);`, direct `deinit`, conversion via `toOwnedSlice`, or returning the container satisfies ownership. An automated quickfix inserts the appropriate `defer container.deinit(allocator);`.
