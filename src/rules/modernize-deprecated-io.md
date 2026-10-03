# `modernize-deprecated-io`

Reports known pre-`std.Io` reader, writer, and buffering adapters reached through `std.io` or `std.Io`.

**Why it matters.** The I/O redesign moves interface and buffer ownership into explicit current types; old adapters delay an otherwise mechanical release migration.

**When it matters.** Enabled by the `modernize` profile. Shape-changing migrations name the replacement but do not edit code automatically.

Other standard-library namespaces, nested `std` members, and declared local
bindings that shadow `std` are skipped.
