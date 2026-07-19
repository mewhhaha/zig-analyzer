# `stale-index-map`

[Rule index](RULES.md)

Reports removal from an indexed sequence when a sibling map or an element field
stores sequence indices and is not updated in the same operation.

**Why it matters.** `swapRemove` moves the last element and ordered removal
shifts later elements, leaving saved indices associated with the wrong value.

**When it matters.** The rule applies when the containing type visibly pairs an
index-valued map with the mutated sequence, or appends bounds-checked sequence
indices into an element field. Removing only the deleted key does not count as
reindexing the element moved by `swapRemove`. For self-references, opaque repair
calls suppress the finding because their effect cannot be disproved locally.
