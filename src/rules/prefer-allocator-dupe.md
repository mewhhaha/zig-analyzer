# `prefer-allocator-dupe`

Reports `std.fmt.allocPrint` (or `allocPrintSentinel` with a `0` sentinel) calls
where the format string has no format specifiers or only contains a single `{s}`
specifier, recommending `allocator.dupe(u8, ...)` or `allocator.dupeZ(u8, ...)`
instead.

**Why it matters.**

`std.fmt.allocPrint` executes a two-pass formatting routine:
1. It formats through a counting writer to measure the required buffer length.
2. It allocates the measured capacity from the allocator.
3. It formats a second time into the allocated buffer.

When duplicating an existing slice or static string, `allocator.dupe` calculates
the slice length in $O(1)$, allocates the buffer directly, and copies the bytes
using SIMD `@memcpy`. Using `allocator.dupe` avoids runtime format string parsing,
eliminates the counting pass, and reduces binary size.

**When it matters.**

This rule flags:
- `std.fmt.allocPrint(allocator, "{s}", .{slice})`
- `std.fmt.allocPrint(allocator, "literal", .{})`
- `std.fmt.allocPrintSentinel(allocator, 0, "{s}", .{slice})`
- `std.fmt.allocPrintSentinel(allocator, 0, "literal", .{})`

It leaves format calls with multiple parameters or formatting specifiers untouched.

## Example

```zig
// Before
const copy = try std.fmt.allocPrint(allocator, "{s}", .{name});
const static_copy = try std.fmt.allocPrint(allocator, "initial_value", .{});

// After
const copy = try allocator.dupe(u8, name);
const static_copy = try allocator.dupe(u8, "initial_value");
```
