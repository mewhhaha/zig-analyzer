# `prefer-array-list-last`

[Rule index](RULES.md)

Reports `list.items[list.items.len - 1]` when `list` is proven to have a standard array-list type.

**Why it matters.** `getLast()` names the operation directly and keeps the list expression in one place.

**When it matters.** The receiver must resolve to an explicitly typed `std.ArrayList` or `std.ArrayListUnmanaged`. The rule does not add an emptiness check; it preserves the original operation's requirement that the list be non-empty. The rewrite is eligible for fix-all.
