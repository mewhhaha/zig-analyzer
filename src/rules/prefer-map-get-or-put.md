# `prefer-map-get-or-put`

[Rule index](RULES.md)

Reports checking key presence via `map.contains(key)` or `map.get(key) == null` followed immediately by `map.put(key, value)`.

```zig
// Bad: checks existence and then re-hashes and re-probes to insert
if (!map.contains(key)) {
    try map.put(key, value);
}

// Good: single hash calculation and single probe sequence
const entry = try map.getOrPut(key);
if (!entry.found_existing) {
    entry.value_ptr.* = value;
}
```

**Why it matters.** Querying a hash map via `contains` or `get` computes the hash of the key and traverses the table's probe sequence. Calling `put` immediately afterwards repeats the entire hash computation and probing traversal. `getOrPut` (or `getOrPutValue` / `getOrPutAssumeCapacity`) performs this check in a single pass, returning a pointer to the newly allocated or existing slot without redundant table searches.

**When it matters.** The rule reports when `map.put` is invoked on the same receiver with the identical key within the body of a guarded `if` block. Unrelated keys and non-standard map types are ignored.
