# `resource-cleanup-on-error-only`

[Rule index](RULES.md)

Reports a resource cleaned up by `errdefer` only, with no successful-path
cleanup or ownership transfer.

**Why it matters.** Error paths release the resource, but successful calls
retain it unintentionally.

**When it matters.** It applies to recognized resource constructors and release
methods in a simple lexical scope.
