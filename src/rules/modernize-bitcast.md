# `modernize-bitcast`

Reports `@bitCast` calls with a syntactically proven array or vector source or
destination for review during a Zig 0.17 migration.

**Why it matters.** Zig 0.17 reinterprets logical bits independently of target
endianness. Array and vector casts that previously followed native memory
order can silently change behavior on big-endian targets while still compiling.

**When it matters.** Enabled by the `modernize` profile. Explicit local and
parameter array or vector types, array literals, and `@as` result types provide
the proof. Scalar casts, slices, pointers, indexed elements, and unknown type
aliases are skipped. The rule requests an audit without an automatic edit;
the new semantics may already be exactly what the code intends.

See [Zig 0.17 `@bitCast` changes](https://ziglang.org/download/0.17.0/release-notes.html#codebitCastcode-changes).
