# `prefer-map-contains`

[Rule index](RULES.md)

Reports `map.get(key) != null` and `map.get(key) == null` when the receiver is proven to have a standard map type.

**Why it matters.** `contains` states that only membership matters and does not make readers infer that the retrieved value is intentionally ignored.

**When it matters.** The receiver must resolve to an explicitly typed `std` hash map, array hash map, or JSON object map. Custom `get` methods and inferred receiver types are left unchanged. The rewrite is eligible for fix-all.
