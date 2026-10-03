# `deprecated-declaration`

Reports references to resolved local and imported declarations marked deprecated
in their doc comments. Recognizes `Deprecated:`, `Deprecated;`, `Deprecated,`,
`Deprecated.`, and `Deprecated in favor of` wording, without regard to case.

**Why it matters.** Zig deprecations otherwise remain prose until a later release removes the declaration and breaks the build.

**When it matters.** Enabled as a warning by default. Lexical bindings, constant
namespace/type/function aliases, explicit receiver types, public reexports,
literal file imports, and `@import("std")` establish declaration identity.
Unknown receivers, mutable namespace/type aliases, shadowed imports, inaccessible
members, and named build modules whose compilation binding is unavailable are
skipped. A comment deprecating only default initialization does not deprecate
the entire type; `modernize-container-init` handles that usage separately.

The diagnostic carries the author's migration advice. Imported public namespace
and type aliases use their own deprecation
markers, allowing current names that internally alias older spellings.
Function and value reexports retain inherited advice. Imports are indexed on
demand; the CLI checks them independently of the project cache, and the editor
uses current open buffers and refreshes importers when dependencies change or
close. Generated translate-c sources remain skipped. Missing, unreadable, or
oversized imported sources do not stop other diagnostics. A warning supplies no
automatic edit because documentation alone cannot establish replacement semantics.
