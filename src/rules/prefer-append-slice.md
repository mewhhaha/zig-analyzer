# `prefer-append-slice`

Reports loops that append slice elements one-by-one into an `ArrayList` or
`ArrayListUnmanaged`, recommending `appendSlice` or `appendSliceAssumeCapacity` instead.

**Why it matters.**

Appending elements individually in a loop (`for (items) |item| list.append(item)`)
incurs:
- Repeated capacity checks and conditional branches on every iteration.
- Potential multiple buffer reallocations and copies as the list grows.
- Missed opportunities for bulk vectorized memory transfer.

Calling `appendSlice(items)` checks capacity and reallocates at most once, then
copies all elements at once using SIMD `@memcpy`.

**When it matters.**

This rule flags single-statement loops calling:
- `list.append(item)`
- `list.append(allocator, item)`
- `list.appendAssumeCapacity(item)`
- `list.appendAssumeCapacity(allocator, item)`

Where the argument passed to `append` is the single iteration capture of the loop.

## Example

```zig
// Before
for (elements) |elem| {
    try list.append(elem);
}

// After
try list.appendSlice(elements);
```
