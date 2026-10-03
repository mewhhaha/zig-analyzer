# `prefer-allocator-dupe`

[Rule index](RULES.md)

Reports allocator `print` and `printSentinel` calls, and legacy
`std.fmt.allocPrint` and `allocPrintSentinel` calls, that only duplicate a string.
The replacement uses `allocator.dupe(u8, ...)` or `allocator.dupeSentinel(u8, ..., 0)`.

**Why it matters.** Direct duplication allocates the required bytes and copies
once, avoiding the formatter and its growing output buffer.

**When it matters.** The format must be a brace-free literal or exactly `"{s}"` with
one argument. Sentinel calls are rewritten only when their final argument is
`0`. Allocator methods require an explicitly typed allocator binding or a
receiver with a recognized allocator role; writer `print` calls stay unchanged.
Calls with other formatting specifiers or escaped format braces stay unchanged.

```zig
// Before
const copy = try allocator.print("{s}", .{name});
const terminated = try allocator.printSentinel("literal", .{}, 0);

// After
const copy = try allocator.dupe(u8, name);
const terminated = try allocator.dupeSentinel(u8, "literal", 0);
```
