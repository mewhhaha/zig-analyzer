# `prefer-write-byte`

[Rule index](RULES.md)

Reports writing a single character via `writeAll` or `print`, recommending `writeByte` instead.

```zig
// Inefficient: slice iteration or runtime format string parsing
try writer.writeAll("}");
try writer.print("\n", .{});
try writer.print("{c}", .{ch});

// Fast: single byte write directly into the stream buffer
try writer.writeByte('}');
try writer.writeByte('\n');
try writer.writeByte(ch);
```

**Why it matters.** `writer.print` parses format strings, decodes flags, and inspects tuple types at runtime. `writer.writeAll` verifies slice lengths and loops through memory chunks. When writing a single character or byte, `writer.writeByte` writes directly to the destination stream or buffer with no formatting or slice machinery.

**When it matters.** The rule reports:
1. `writer.writeAll("c")` with 1-character string literals.
2. `writer.print("c", .{})` with 1-character string literals and empty argument tuples.
3. `writer.print("{c}", .{ch})` with single character arguments.
Multi-byte strings and complex format expressions are ignored.
